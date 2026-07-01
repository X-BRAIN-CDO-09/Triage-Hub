"""
Unit validation tests — ai-engine
Đối chiếu với: AIO_Contract/ai-api-contract.md
  § Request Headers  → missing/mismatch X-Tenant-Id, X-Correlation-Id → 400
  § Request Body     → invalid environment enum → 422
  § Response Body    → required fields, status values
  § Deterministic    → INSUFFICIENT_CONTEXT khi không có context
  § Error Codes      → 400, 422 per schema
"""

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


# ---------------------------------------------------------------------------
# Fixture: payload hợp lệ đầy đủ để tái sử dụng
# ---------------------------------------------------------------------------


def _valid_payload(
    tenant_id: str = "tenant-A",
    correlation_id: str = "test-corr-123",
    incident_id: str = "inc-01",
    environment: str = "sandbox",
) -> dict:
    return {
        "correlation_id": correlation_id,
        "tenant_id": tenant_id,
        "incident_id": incident_id,
        "environment": environment,
        "received_at": "2026-06-22T08:05:00Z",
        "alert": {
            "alert_id": "alert-001",
            "source": "synthetic-pack",
            "service": "checkout-api",
            "severity": "high",
            "title": "High p95 latency on checkout-api",
            "started_at": "2026-06-22T08:00:00Z",
        },
    }


def _valid_headers(
    tenant_id: str = "tenant-A",
    correlation_id: str = "test-corr-123",
) -> dict:
    return {
        "X-Tenant-Id": tenant_id,
        "X-Correlation-Id": correlation_id,
        "Authorization": "Bearer test-token",
    }


# ---------------------------------------------------------------------------
# Header validation
# Contract: "X-Tenant-Id required; missing → 400 or 422"
# ---------------------------------------------------------------------------


def test_triage_missing_tenant_header():
    """Thiếu X-Tenant-Id → FastAPI trả 422 (header required by signature)."""
    headers = {"X-Correlation-Id": "test-corr-123"}
    response = client.post("/v1/triage", json=_valid_payload(), headers=headers)
    # FastAPI raises 422 cho missing required header parameter
    assert response.status_code == 422


def test_triage_missing_correlation_header():
    """Thiếu X-Correlation-Id → FastAPI trả 422 (header required by signature)."""
    headers = {"X-Tenant-Id": "tenant-A"}
    response = client.post("/v1/triage", json=_valid_payload(), headers=headers)
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# Tenant mismatch
# Contract: "X-Tenant-Id must match body tenant_id → 400"
# ---------------------------------------------------------------------------


def test_triage_mismatch_tenant_returns_400():
    """
    X-Tenant-Id khác body.tenant_id → 400 (bắt buộc theo contract).
    Không được accept 422 — 422 là schema error, không phải isolation error.
    """
    headers = _valid_headers(tenant_id="tenant-A")
    payload = _valid_payload(tenant_id="tenant-B")  # mismatch
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 400


def test_triage_mismatch_correlation_returns_400():
    """X-Correlation-Id khác body.correlation_id → 400."""
    headers = _valid_headers(correlation_id="corr-HEADER")
    payload = _valid_payload(correlation_id="corr-BODY")  # mismatch
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 400


# ---------------------------------------------------------------------------
# Body validation — environment enum
# Contract: environment must be one of prod | staging | sandbox → 422
# ---------------------------------------------------------------------------


def test_triage_invalid_environment_returns_422():
    """environment không nằm trong enum hợp lệ → Pydantic 422."""
    headers = _valid_headers()
    payload = _valid_payload(environment="invalid_env")
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 422


@pytest.mark.parametrize("env", ["prod", "staging", "sandbox"])
def test_triage_valid_environments_accepted(env: str):
    """Các giá trị environment hợp lệ phải được accept (không bị 422)."""
    headers = _valid_headers()
    payload = _valid_payload(environment=env)
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code != 422


# ---------------------------------------------------------------------------
# Response shape — required fields
# Contract § Response Body: incident_id, classification, severity, confidence,
#   status, suspected_root_cause.summary, suspected_root_cause.evidence,
#   recommended_actions, ticket_payload, audit_id
# ---------------------------------------------------------------------------


def test_triage_response_required_fields():
    """
    Response 200 phải chứa đầy đủ required fields theo contract.
    Payload không có metrics/logs/deploys → INSUFFICIENT_CONTEXT vẫn phải
    trả đủ fields (không được thiếu field).
    """
    headers = _valid_headers()
    payload = _valid_payload()  # không có metrics/logs → INSUFFICIENT_CONTEXT
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 200

    body = response.json()
    # Required fields theo contract
    assert "incident_id" in body
    assert "classification" in body
    assert "severity" in body
    assert "confidence" in body
    assert "status" in body
    assert "suspected_root_cause" in body
    assert "summary" in body["suspected_root_cause"]
    assert "evidence" in body["suspected_root_cause"]
    assert isinstance(body["suspected_root_cause"]["evidence"], list)
    assert "recommended_actions" in body
    assert isinstance(body["recommended_actions"], list)
    assert "ticket_payload" in body
    assert "audit_id" in body


def test_triage_response_incident_id_matches_request():
    """incident_id trong response phải khớp với request."""
    headers = _valid_headers()
    payload = _valid_payload(incident_id="inc-check-001")
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 200
    assert response.json()["incident_id"] == "inc-check-001"


# ---------------------------------------------------------------------------
# Response status values
# Contract: status ∈ {DIAGNOSED, INVESTIGATE, INSUFFICIENT_CONTEXT,
#                     UNSAFE_SUGGESTION_BLOCKED}
# ---------------------------------------------------------------------------

VALID_STATUSES = {"DIAGNOSED", "INVESTIGATE", "INSUFFICIENT_CONTEXT", "UNSAFE_SUGGESTION_BLOCKED"}


def test_triage_response_status_is_valid_enum():
    """status trong response phải là một trong 4 giá trị hợp lệ theo contract."""
    headers = _valid_headers()
    payload = _valid_payload()
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 200
    assert response.json()["status"] in VALID_STATUSES


def test_triage_insufficient_context_when_no_telemetry():
    """
    Contract § Deterministic Skeleton Behavior:
    'Required alert exists but all context arrays/ownership are empty
     → INSUFFICIENT_CONTEXT'
    Payload không có metrics, logs, traces, deploys, ownership.
    """
    headers = _valid_headers()
    payload = _valid_payload()  # chỉ có alert, không có telemetry context
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 200
    assert response.json()["status"] == "INSUFFICIENT_CONTEXT"


# ---------------------------------------------------------------------------
# Recommended actions — type enum
# Contract: type ∈ {HUMAN_REVIEW, RUNBOOK_CHECK, ROLLBACK_CONSIDER,
#                   ESCALATE_OWNER, OBSERVE}
# API must not return auto-executing action types.
# ---------------------------------------------------------------------------

VALID_ACTION_TYPES = {"HUMAN_REVIEW", "RUNBOOK_CHECK", "ROLLBACK_CONSIDER", "ESCALATE_OWNER", "OBSERVE"}


def test_triage_recommended_actions_type_valid():
    """Mọi action trong recommended_actions phải có type hợp lệ theo contract."""
    headers = _valid_headers()
    payload = _valid_payload()
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 200
    actions = response.json()["recommended_actions"]
    for action in actions:
        assert action["type"] in VALID_ACTION_TYPES, (
            f"Action type '{action['type']}' không nằm trong allowed types của contract"
        )


# ---------------------------------------------------------------------------
# ticket_payload shape
# Contract: ticket_payload phải có project, summary, description, labels, fields
# ---------------------------------------------------------------------------


def test_triage_ticket_payload_shape():
    """ticket_payload phải có đủ fields để CDO tạo Jira ticket."""
    headers = _valid_headers()
    payload = _valid_payload()
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 200
    ticket = response.json()["ticket_payload"]
    assert "project" in ticket
    assert "summary" in ticket
    assert "description" in ticket
    assert "labels" in ticket
    assert isinstance(ticket["labels"], list)
    assert "fields" in ticket
    assert "audit_id" in ticket["fields"]
