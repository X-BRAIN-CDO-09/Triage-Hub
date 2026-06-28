# Enum & Topology Mismatch Report — TF1 Triage Hub

**Ngày kiểm tra:** 2026-06-25
**Phạm vi:** 4 AI Ops contracts <-> CDO docs (`docs/`)
**Tổng mismatch:** 8 (6 HIGH · 1 MEDIUM · 1 LOW)

> [!CAUTION]
> **6 mismatch HIGH** cần fix trước buổi chấm T5. Nếu không sửa, E2E test sẽ fail và AI API sẽ reject request với lỗi `400` / `404`.

---

## Tổng hợp toàn bộ

| ID | Nhóm | Mức độ | Vấn đề | Fix ở đâu |
|---|---|---|---|---|
| M1 | classification | HIGH | `CRITICAL_INCIDENT` -> `critical_service_down` | CDO E2E `9_1_critical_incident_scenario.md` |
| M2 | classification | HIGH | `LATENCY_DEGRADATION` -> `latency_degradation` | CDO E2E `9_2_latency_degradation_scenario.md` |
| M3 | classification | HIGH | `INVESTIGATE` -> `noisy_or_ambiguous_alert` | CDO E2E `9_3_false_positive_scebario.md` |
| M4 | field confusion | HIGH | `classification: INVESTIGATE` -> `status: INVESTIGATE` | CDO E2E `9_3_false_positive_scebario.md` |
| M5 | severity case | MEDIUM | lowercase vs UPPERCASE chua thong nhat | AI team chot, ca 2 ben update |
| T1 | environment | HIGH | `dev` khong co trong contract enum -> phai la `sandbox` | CDO `docs/reports/04_deployment_design.md` |
| T2 | endpoint path | HIGH | `/v1/alerts` khong ton tai -> phai la `/v1/triage` | CDO E2E ca 3 scenario file |
| T3 | ECS name | LOW | Placeholder `--cluster prod` != `tf-1-aiops-cluster` | CDO E2E `9_1_critical_incident_scenario.md` |

---

## Chi tiet tung mismatch

---

### M1 — `classification`: `CRITICAL_INCIDENT` HIGH

**Contract dung** (`ai-api-contract.md` dong 213):
```
critical_service_down
```

**CDO docs dung** (`docs/E2E_validate/9_1_critical_incident_scenario.md` dong 269):
```json
"classification": "CRITICAL_INCIDENT"
```

**Fix:**
```diff
- "classification": "CRITICAL_INCIDENT"
+ "classification": "critical_service_down"
+ "status": "DIAGNOSED"
```

---

### M2 — `classification`: `LATENCY_DEGRADATION` HIGH

**Contract dung** (`ai-api-contract.md` dong 214):
```
latency_degradation
```

**CDO docs dung** (`docs/E2E_validate/9_2_latency_degradation_scenario.md` dong 217):
```json
"classification": "LATENCY_DEGRADATION"
```

**Fix:**
```diff
- "classification": "LATENCY_DEGRADATION"
+ "classification": "latency_degradation"
+ "status": "DIAGNOSED"
```

---

### M3 — `classification`: `INVESTIGATE` HIGH

**Contract dung** (`ai-api-contract.md` dong 215):
```
noisy_or_ambiguous_alert
```

**CDO docs dung** (`docs/E2E_validate/9_3_false_positive_scebario.md` dong 276):
```json
"classification": "INVESTIGATE"
```

**Fix:**
```diff
- "classification": "INVESTIGATE"
+ "classification": "noisy_or_ambiguous_alert"
```

---

### M4 — Field confusion: `status` vs `classification` HIGH

**Contract dinh nghia** (`ai-api-contract.md` dong 199-204):

| Field | Enum values |
|---|---|
| `status` | `DIAGNOSED` / `INVESTIGATE` / `INSUFFICIENT_CONTEXT` / `UNSAFE_SUGGESTION_BLOCKED` |
| `classification` | `latency_degradation` / `critical_service_down` / `noisy_or_ambiguous_alert` / `insufficient_context` |

`INVESTIGATE` la gia tri cua `status`, KHONG phai `classification`.

**CDO docs dung sai** (`docs/E2E_validate/9_3_false_positive_scebario.md`):
```json
{
  "classification": "INVESTIGATE"
}
```

**Fix — response mau dung:**
```json
{
  "classification": "noisy_or_ambiguous_alert",
  "status": "INVESTIGATE",
  "confidence": 0.32
}
```

---

### M5 — `severity` case: lowercase vs UPPERCASE MEDIUM

**Contract dinh nghia** (`telemetry-contract.md` dong 81) — request body:
```
critical | high | medium | low | unknown   (lowercase)
```

**CDO E2E docs dung** — response mau:
```json
"severity": "CRITICAL"
"severity": "MEDIUM"
"severity": "HIGH"
```

| Field | Contract | CDO E2E docs |
|---|---|---|
| `alert.severity` (request) | `critical` (lowercase) | N/A |
| `severity` (response) | `high` theo example | `CRITICAL` / `MEDIUM` / `HIGH` |

> **Quyet dinh can AI team chot truoc T5:**
> - Option A: Thong nhat UPPERCASE cho toan bo enum value response
> - Option B: Thong nhat lowercase -> CDO cap nhat 3 file E2E

---

### T1 — `environment`: `dev` khong ton tai trong contract HIGH

**Contract dinh nghia** — tat ca 4 contracts:
```
prod | staging | sandbox
```

**CDO infra docs** (`docs/reports/04_deployment_design.md` dong 127-131):
```
Dev | Staging | Prod
```

| CDO infra env | AI contract enum | Khop? |
|---|---|---|
| `Dev` | `sandbox` | Khong co mapping ro |
| `Staging` | `staging` | OK |
| `Prod` | `prod` | OK |

**Rui ro:** Neu CDO gui request voi `"environment": "dev"` -> AI API tra `400` validation error.

**Fix — them vao `docs/reports/04_deployment_design.md` section 5:**
```
Luu y: CDO infra environment `Dev` phai map sang AI contract value `sandbox`.
Khi goi POST /v1/triage, field `environment` phai la `sandbox` (khong phai `dev`).
```

---

### T2 — Endpoint path: `/v1/alerts` khong ton tai HIGH

**Contract dinh nghia** (`ai-api-contract.md` dong 46):
```
POST /v1/triage
```

**CDO E2E docs dung** (ca 3 scenario files):
```
POST /v1/alerts
```

`POST /v1/alerts` KHONG TON TAI trong AI API contract.
AI engine chi expose 2 endpoint: `GET /healthz` va `POST /v1/triage`.

**Kien truc dung theo contract:**
```
CDO phat hien alert
  -> CDO thu thap context (logs, metrics, traces, deploy history)
  -> CDO build normalized context bundle
  -> CDO goi POST /v1/triage   <- endpoint dung
  -> AI tra diagnosis response
```

**Fix — cap nhat ca 3 file E2E scenario:**
```diff
- POST /v1/alerts
+ POST /v1/triage
```

CDO can bo sung buoc "Build context bundle" vao luong E2E truoc khi goi `/v1/triage`.

---

### T3 — ECS cluster name: placeholder chua update LOW

**Contract dinh nghia** (`deployment-contract.md` dong 36-37):
```
Cluster:  tf-1-aiops-cluster
Service:  tf1-ai-triage-engine
```

**CDO chaos test** (`docs/E2E_validate/9_1_critical_incident_scenario.md` dong 188-194):
```bash
aws ecs update-service \
  --cluster prod \
  --service api-service \
  --desired-count 0
```

**Fix:**
```diff
  aws ecs update-service \
-   --cluster prod \
-   --service api-service \
+   --cluster tf-1-aiops-cluster \
+   --service tf1-ai-triage-engine \
    --desired-count 0
```

---

## Bang enum reference — Nguon dung duy nhat

### `classification` (snake_case, lowercase)

| Gia tri | Khi nao dung |
|---|---|
| `critical_service_down` | Service down, availability = 0%, error rate spike |
| `latency_degradation` | P95/P99 latency vuot SLO |
| `noisy_or_ambiguous_alert` | Tin hieu yeu, false positive, khong du evidence |
| `insufficient_context` | Thieu required fields hoac empty context arrays |

### `status` (UPPERCASE)

| Gia tri | Khi nao dung |
|---|---|
| `DIAGNOSED` | Du context, AI dua ra diagnosis |
| `INVESTIGATE` | Tin hieu mo ho, confidence thap |
| `INSUFFICIENT_CONTEXT` | Thieu context, khong the RCA |
| `UNSAFE_SUGGESTION_BLOCKED` | Suggestion vi pham safety boundary |

### `environment` (lowercase)

| Gia tri AI contract | CDO infra tuong ung |
|---|---|
| `sandbox` | `Dev` (capstone build env) |
| `staging` | `Staging` |
| `prod` | `Prod` |

### `alert.severity` — Can thong nhat (pending AI team decision)

| Gia tri theo contract | Gia tri CDO E2E dung |
|---|---|
| `critical` | `CRITICAL` |
| `high` | `HIGH` |
| `medium` | `MEDIUM` |
| `low` | `low` |
| `unknown` | — |

### `recommended_actions[].type` (UPPERCASE)

| Gia tri | Y nghia |
|---|---|
| `HUMAN_REVIEW` | Yeu cau engineer review thu cong |
| `RUNBOOK_CHECK` | Tham chieu runbook cu the |
| `ROLLBACK_CONSIDER` | Xem xet rollback deploy |
| `ESCALATE_OWNER` | Escalate len owner team |
| `OBSERVE` | Quan sat them, khong action ngay |

---

## Action items truoc T5

- [ ] **M1, M2, M3, M4** — CDO cap nhat expected response trong 3 file E2E scenario (9_1, 9_2, 9_3)
- [ ] **T2** — CDO doi endpoint `POST /v1/alerts` -> `POST /v1/triage` toan bo E2E docs
- [ ] **T1** — CDO them mapping note vao `docs/reports/04_deployment_design.md` section 5
- [ ] **M5** — AI team chot convention uppercase/lowercase, announce cho CDO
- [ ] **T3** — CDO cap nhat ECS cluster name trong chaos test script

---

*Source of truth: `ai-api-contract.md` · `telemetry-contract.md` · `deployment-contract.md` · `observability-data-contract.md`*
