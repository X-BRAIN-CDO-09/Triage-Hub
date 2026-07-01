#!/usr/bin/env python3
"""
Assignee Resolver — bootstrap/refresh JIRA_HISTORY mapping cho AI engine.

Bài toán: AI engine (suggest_assignee) gợi ý assignee bằng cách đọc record
    JIRA_HISTORY#{tenant}#{environment}#{service}  /  SK=SUGGESTION
trong DynamoDB. Nếu record trống -> Slack hiện "No specific assignee suggested".

Script này TÍNH assignee bằng thuật toán (không hardcode trong code AI):
  1) LỊCH SỬ JIRA THẬT: query các incident cũ của service, chọn người được
     assign nhiều nhất (tie-break theo lần cập nhật gần nhất).
  2) FALLBACK ROSTER: nếu service chưa có lịch sử -> lấy primary on-call của
     owner_team từ team_roster.json (cấu hình ownership, sửa được).
Kết quả ghi vào cùng bảng DynamoDB mà AI engine đọc. KHÔNG sửa code AI engine.

Chạy:
    python resolve_assignees.py --dry-run      # xem trước, không ghi
    python resolve_assignees.py                # ghi thật vào DynamoDB

Cấu hình qua env (đều có default cho sandbox):
    AWS_REGION                (us-east-1)
    AIOPS_DYNAMODB_TABLE      (triage-hub-state-sandbox)
    JIRA_SECRET_ID            (triage-hub-jira_api_token-sandbox)
    ASSIGNEE_ENVIRONMENT      (sandbox)
    ASSIGNEE_TENANTS          (tenant-a[,tenant-b,...])
    HISTORY_LOOKBACK_DAYS     (90)
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any

import boto3

HERE = Path(__file__).resolve().parent
# Datapack ownership (service -> owner_team) — nguồn ground-truth đã có sẵn.
OWNERSHIP_GLOBS = [
    HERE.parent.parent
    / "capstone/tf-1/devops/app/ai-engine/datapack/scenarios",
]

REGION = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "us-east-1"
DDB_TABLE = os.getenv("AIOPS_DYNAMODB_TABLE", "triage-hub-state-sandbox")
JIRA_SECRET_ID = os.getenv("JIRA_SECRET_ID", "triage-hub-jira_api_token-sandbox")
ENVIRONMENT = os.getenv("ASSIGNEE_ENVIRONMENT", "sandbox")
TENANTS = [t.strip() for t in os.getenv("ASSIGNEE_TENANTS", "tenant-a").split(",") if t.strip()]
LOOKBACK_DAYS = int(os.getenv("HISTORY_LOOKBACK_DAYS", "90"))


# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
def load_service_ownership() -> dict[str, str]:
    """Scan datapack ownership.json -> {service: owner_team}."""
    mapping: dict[str, str] = {}
    for root in OWNERSHIP_GLOBS:
        if not root.exists():
            continue
        for path in root.rglob("ownership.json"):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            service = data.get("service")
            owner_team = data.get("owner_team")
            if service and owner_team:
                mapping[service] = owner_team
    return mapping


def load_roster(path: Path) -> dict[str, list[str]]:
    """team_roster.json -> {owner_team: [oncall_accountId, ...]}."""
    data = json.loads(path.read_text(encoding="utf-8"))
    teams = data.get("teams", {})
    roster: dict[str, list[str]] = {}
    for team, cfg in teams.items():
        oncall = cfg.get("oncall") or []
        roster[team] = [a for a in oncall if isinstance(a, str) and a]
    return roster, data.get("_members", {})


# ---------------------------------------------------------------------------
# Jira
# ---------------------------------------------------------------------------
def get_jira_creds() -> dict[str, str]:
    sm = boto3.client("secretsmanager", region_name=REGION)
    raw = sm.get_secret_value(SecretId=JIRA_SECRET_ID)["SecretString"]
    creds = json.loads(raw)
    return {"email": creds["email"], "token": creds["token"], "base_url": creds["base_url"].rstrip("/")}


def jira_search(creds: dict[str, str], jql: str, fields: list[str], max_results: int = 50) -> list[dict[str, Any]]:
    """Search issues. Dùng endpoint /search/jql (Cloud), fallback /search."""
    auth = base64.b64encode(f"{creds['email']}:{creds['token']}".encode()).decode()
    headers = {"Authorization": f"Basic {auth}", "Accept": "application/json", "Content-Type": "application/json"}
    body = json.dumps({"jql": jql, "fields": fields, "maxResults": max_results}).encode()

    for endpoint in ("/rest/api/3/search/jql", "/rest/api/3/search"):
        req = urllib.request.Request(creds["base_url"] + endpoint, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                payload = json.loads(resp.read().decode())
                return payload.get("issues", [])
        except urllib.error.HTTPError as exc:
            if exc.code in (404, 410):  # endpoint không tồn tại -> thử cái kế
                continue
            print(f"  ! Jira search HTTP {exc.code}: {exc.read().decode()[:200]}", file=sys.stderr)
            return []
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"  ! Jira search error: {exc}", file=sys.stderr)
            return []
    return []


def history_assignees(creds: dict[str, str], service: str) -> list[dict[str, Any]]:
    """Trả về thống kê assignee từ incident cũ của service (đã giảm dần theo count)."""
    safe = service.replace('"', "")
    jql = (
        f'assignee IS NOT EMPTY AND updated >= "-{LOOKBACK_DAYS}d" '
        f'AND (labels = "service-{safe}" OR labels = "{safe}" OR summary ~ "\\"{safe}\\"") '
        f"ORDER BY updated DESC"
    )
    issues = jira_search(creds, jql, fields=["assignee", "updated"])
    stats: dict[str, dict[str, Any]] = {}
    order = 0
    for issue in issues:
        assignee = (issue.get("fields") or {}).get("assignee")
        if not assignee or not assignee.get("accountId"):
            continue
        acc = assignee["accountId"]
        entry = stats.setdefault(
            acc,
            {"account_id": acc, "display_name": assignee.get("displayName") or acc, "count": 0, "first_seen_order": order},
        )
        entry["count"] += 1
        order += 1
    ranked = sorted(stats.values(), key=lambda e: (-e["count"], e["first_seen_order"]))
    return ranked


# ---------------------------------------------------------------------------
# Resolution algorithm
# ---------------------------------------------------------------------------
def resolve_service(
    creds: dict[str, str],
    service: str,
    owner_team: str,
    roster: dict[str, list[str]],
    members: dict[str, str],
) -> dict[str, Any] | None:
    # 1) Lịch sử Jira thật
    ranked = history_assignees(creds, service)
    if ranked:
        top = ranked[0]
        return {
            "account_id": top["account_id"],
            "suggestion_reason": (
                f"Suggested from {top['count']} past '{service}' incident(s) "
                f"most frequently handled by {top['display_name']}."
            ),
            "source": "jira_history_stats",
        }
    # 2) Fallback: primary on-call của owner_team
    oncall = roster.get(owner_team) or []
    if oncall:
        primary = oncall[0]
        name = members.get(primary, primary)
        return {
            "account_id": primary,
            "suggestion_reason": (
                f"No prior '{service}' incident history; routed to {owner_team} "
                f"primary on-call ({name})."
            ),
            "source": "team_roster_oncall",
        }
    # 3) Không có gì -> để AI route-to-team (không ghi record)
    return None


def write_record(table: Any, tenant: str, env: str, service: str, owner_team: str, decision: dict[str, Any]) -> None:
    record = {
        "account_id": decision["account_id"],
        # alias để khớp mọi nhánh đọc của AI engine (account_id / assignee_account_id / suggested_assignee_account_id)
        "suggested_assignee_account_id": decision["account_id"],
        "suggestion_reason": decision["suggestion_reason"],
        "source": decision["source"],
        "service": service,
        "owner_team": owner_team,
        "computed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    table.put_item(
        Item={
            "PK": f"JIRA_HISTORY#{tenant}#{env}#{service}",
            "SK": "SUGGESTION",
            "record": record,
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve & seed JIRA_HISTORY assignee mappings.")
    parser.add_argument("--dry-run", action="store_true", help="Chỉ in ra, không ghi DynamoDB.")
    parser.add_argument("--roster", default=str(HERE / "team_roster.json"))
    parser.add_argument("--service", help="Chỉ xử lý 1 service (mặc định: tất cả service trong ownership).")
    args = parser.parse_args()

    ownership = load_service_ownership()
    roster, members = load_roster(Path(args.roster))
    creds = get_jira_creds()

    if args.service:
        ownership = {args.service: ownership.get(args.service, "")}

    print(f"Table={DDB_TABLE} region={REGION} env={ENVIRONMENT} tenants={TENANTS} lookback={LOOKBACK_DAYS}d")
    print(f"Services: {len(ownership)} | Roster teams: {list(roster)} | dry_run={args.dry_run}\n")

    table = None
    if not args.dry_run:
        table = boto3.resource("dynamodb", region_name=REGION).Table(DDB_TABLE)

    written = skipped = 0
    for service, owner_team in sorted(ownership.items()):
        decision = resolve_service(creds, service, owner_team, roster, members)
        if not decision:
            print(f"[skip ] {service:<22} owner={owner_team:<22} -> no history & no roster on-call")
            skipped += 1
            continue
        for tenant in TENANTS:
            key = f"JIRA_HISTORY#{tenant}#{ENVIRONMENT}#{service}"
            if args.dry_run:
                print(f"[DRY  ] {key}\n         -> {decision['account_id']} ({decision['source']})\n         {decision['suggestion_reason']}")
            else:
                write_record(table, tenant, ENVIRONMENT, service, owner_team, decision)
                print(f"[write] {key} -> {decision['account_id']} ({decision['source']})")
            written += 1

    print(f"\nDone. records={written} skipped_services={skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
