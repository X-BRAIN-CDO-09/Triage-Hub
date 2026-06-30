# 09 — TF1 Triage Hub Test Plan

> Version: 1.0 | Owner: Thi | Last Updated: 2026-06-28

## Tổng quan

Test plan 6 phase cho TF1 Triage Hub, được tối ưu để **chạy tối đa ở local** trước khi tốn tiền deploy lên AWS.

### Chiến lược tiết kiệm chi phí

| AWS Service | Local Replacement | Chi phí |
|---|---|---|
| EKS | uvicorn trực tiếp / Docker container | $0 |
| Bedrock/LLM | `AGENTCORE_LLM_ENABLED=false` (deterministic) | $0 |
| SQS | LocalStack SQS | $0 |
| Secrets Manager | LocalStack Secrets | $0 |
| S3 / DynamoDB | LocalStack / file-based audit | $0 |
| Lambda deploy | `node index.js` trực tiếp + Jest mock | $0 |
| Slack / Jira | `mendhak/http-https-echo` mock webhook | $0 |
| API Gateway | `curl` trực tiếp | $0 |
| EKS (full E2E) | Docker Compose với tf1-api image | $0 |

---

## Phase 0 — Prerequisite (Production Only)

> Chỉ cần khi deploy thật. Bỏ qua khi test local.

| Việc | Chi tiết | Owner |
|---|---|---|
| Apply infra sandbox | `terraform apply` | Tiến |
| ArgoCD sync | root-app sync 7 add-ons + triage-hub | Bạn |
| Điền Secrets Manager | `service_auth_token`, `triage-hub/ai-engine` | Team |
| Patch sau apply | TG ARN + SQS queueURL | Bạn |

---

## Phase 1 — Local Unit + Eval Harness ⏱️ 1 ngày | $0

> **Chạy NGAY — không cần Docker, không cần AWS**

### 1.1 AI Engine Unit Tests

```powershell
cd capstone/tf-1/devops/app/ai-engine
$env:AGENTCORE_LLM_ENABLED = "false"
$env:SERVICE_AUTH_TOKEN = "local-dev-token-abc123"
python -m pytest tests/test_aiops_pipeline.py -v
```

**Pass**: tất cả xanh hết

### 1.2 Eval Harness — 4 Golden Samples

```powershell
# Start engine
$env:AGENTCORE_LLM_ENABLED = "false"
$env:SERVICE_AUTH_TOKEN = "local-dev-token-abc123"
python -m uvicorn app.main:app --port 8081

# Test từng sample (terminal khác)
.\scripts\e2e-smoke.ps1 -Phase 1
```

| Sample | Expected Status | Expected Classification |
|---|---|---|
| `critical-service-down.request.json` | `DIAGNOSED` | `critical_service_down` |
| `latency-degradation.request.json` | `DIAGNOSED` | `latency_degradation` |
| `noisy-alert.request.json` | `INVESTIGATE` | `noisy_or_ambiguous_alert` |
| `insufficient-context.request.json` | `INSUFFICIENT_CONTEXT` | `insufficient_context` |

**Pass**: classification + status khớp ≥ 4/4

### 1.3 Lambda Unit Tests (Jest — no AWS)

```powershell
cd tests/local
npm install
npm test
```

| Test Suite | Cases | Pass Criterion |
|---|---|---|
| alert-ingest | missing body, missing tenant_id, happy path, SQS failure | All pass |
| push-to-ai | Authorization header, engine 4xx/5xx, batch, no ARN | All pass |

---

## Phase 2 — Deployed Smoke (Docker Local) ⏱️ 0.5 ngày | $0

> Yêu cầu: Docker Desktop + `docker compose -f docker-compose.local.yml up -d`

```powershell
.\scripts\local-setup.ps1    # seed LocalStack queue + secret
.\scripts\e2e-smoke.ps1 -Phase 2
```

| Test | Pass Criterion |
|---|---|
| `/healthz` | 200, status=ok |
| `/readyz` | 200 |
| `/v1/triage` (critical) | DIAGNOSED / critical_service_down |
| Audit record | audit_id tồn tại, record_type=triage_decision |
| Tenant isolation | X-Tenant-Id sai → 400 |
| Auth enforcement | Invalid token → 401 |

---

## Phase 3 — Integration Simulation ⏱️ 1 ngày | $0

> SQS → Lambda → Engine, tất cả local

```powershell
.\scripts\e2e-smoke.ps1 -Phase 3
```

| Mắt xích | Test | Pass |
|---|---|---|
| alert-ingest contract | Thiếu tenant_id → 400 | ✓ |
| SQS message landing | Queue depth ≥ 1 | ✓ |
| push-to-ai → engine | Engine trả DIAGNOSED | ✓ |
| Idempotency | Same correlation_id → cùng kết quả | ✓ |

> **Production equivalent**: Phase 3 real của Tiến/Hoàng/Phong chạy với API GW + AWS SQS thật.

---

## Phase 4 — Full E2E (Script) ⏱️ 1 ngày

### 4A — Synthetic E2E (Local Docker)

```powershell
.\scripts\e2e-smoke.ps1 -Phase all
```

7 checkpoints:
1. alert-ingest → 202 Accepted
2. SQS queue depth +1
3. push-to-ai forwards → engine
4. engine returns DIAGNOSED
5. audit record created
6. (notify-dispatcher — manual check mock-webhook at localhost:9999)
7. (jira-dispatcher — manual check mock-webhook at localhost:9999)

### 4B — Chaos (Production only)

Theo `docs/E2E_validate/thuc_hien_9_1.md` — ngắt DB. Kỳ vọng: `critical_service_down` (không phải CRITICAL_INCIDENT).

---

## Phase 5 — Non-Functional (Load + Chaos) ⏱️ 2 ngày | $0 locally

### 5.1 Load Test (k6)

```powershell
# Install k6: winget install k6 --source winget
k6 run load/k6-local.js
# Hoặc custom duration:
k6 run --vus 2 --duration 3m load/k6-local.js
```

**Pass criterion**: p99 < 2000ms, success rate > 95%, errors < 5

### 5.2 Tenant Isolation

```powershell
# Gửi tenant-A request, query tenant-B audit → expect 404
$resp = Invoke-RestMethod "http://localhost:8080/v1/triage" -Method POST `
    -Body (Get-Content "capstone/tf-1/devops/app/ai-engine/samples/critical-service-down.request.json" -Raw) `
    -ContentType "application/json" `
    -Headers @{ "X-Tenant-Id"="tenant-a"; "X-Correlation-Id"="corr-critical-001"; "Authorization"="Bearer local-dev-token-abc123" }

# Query audit với wrong tenant → 404
Invoke-RestMethod "http://localhost:8080/v1/audit/$($resp.audit_id)" `
    -Headers @{ "X-Tenant-Id"="WRONG-TENANT"; "Authorization"="Bearer local-dev-token-abc123" }
# Expected: 404
```

### 5.3 Idempotency

Tích hợp vào Phase 3 script — same correlation_id → identical classification + status.

### 5.4 DLQ / Poison Message

```powershell
# Gửi message rác vào SQS (thiếu required fields)
aws --endpoint-url=http://localhost:4566 sqs send-message `
    --queue-url http://localhost:4566/000000000000/triage-buffer-local `
    --message-body '{"invalid":"payload"}' `
    --region us-east-1
# push-to-ai sẽ throw → SQS retry → vào DLQ
# Verify DLQ depth:
aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes `
    --queue-url http://localhost:4566/000000000000/triage-buffer-local-dlq `
    --attribute-names ApproximateNumberOfMessages
```

---

## Phase 6 — Continuous (Prod-grade) ⏱️ Ongoing

| Test | Tool |
|---|---|
| Synthetic monitoring | CloudWatch Synthetics (mỗi 5 phút) |
| SLO burn-rate alert | Prometheus/Grafana |
| AI quality regression | Eval harness chạy mỗi đêm (golden) |

**Local equivalent**: Chạy `e2e-smoke.ps1 -Phase 1` trong CI pipeline (`.github/workflows/ci-ai-engine.yml`).

---

## Phần của BẠN (Thi) — Checklist

```
[ ] Phase 1: pytest xanh hết
[ ] Phase 1: 4/4 golden eval pass
[ ] Phase 1: Jest Lambda unit pass
[ ] Phase 2: health + triage smoke pass (Docker)
[ ] Phase 2: audit record verified
[ ] Phase 2: tenant isolation + auth enforcement
[ ] Phase 3: SQS landed + push-to-ai sim pass
[ ] Phase 4A: e2e-smoke.ps1 -Phase all pass
[ ] Phase 5: k6 p99 < 2s
[ ] Phase 5: tenant isolation 0 leak
[ ] Phase 5: DLQ poison message verified
```

## Quick Start — Chạy Ngay (No Docker)

```powershell
# 1. Cài dependency Python
cd capstone/tf-1/devops/app/ai-engine
pip install -r requirements.txt

# 2. Set env vars
$env:AGENTCORE_LLM_ENABLED = "false"
$env:SERVICE_AUTH_TOKEN = "local-dev-token-abc123"
$env:AIOPS_OBSERVABILITY_ENABLED = "false"

# 3. pytest
python -m pytest tests/test_aiops_pipeline.py -v

# 4. Eval harness
cd ../../../../..  # back to Triage-Hub root
.\scripts\e2e-smoke.ps1 -Phase 1
```
