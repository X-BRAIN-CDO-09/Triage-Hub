# Enum Mismatch Report — TF1 Triage Hub
**Kiểm tra ngày:** 2026-06-25  
**So sánh:** 4 AI Ops contracts ↔ CDO docs (`docs/`)  
**Người kiểm tra:** Antigravity (AI assistant)

---

## Tóm tắt nhanh

| Nhóm enum | AI Contract | CDO Docs | Trạng thái |
|---|---|---|---|
| `environment` | `prod`, `staging`, `sandbox` | ✅ Khớp | ✅ OK |
| `alert.severity` | `critical`, `high`, `medium`, `low`, `unknown` | ⚠️ Docs dùng `CRITICAL`, `MEDIUM`, `HIGH` (viết hoa) | ⚠️ MISMATCH (case) |
| `status` (response) | `DIAGNOSED`, `INVESTIGATE`, `INSUFFICIENT_CONTEXT`, `UNSAFE_SUGGESTION_BLOCKED` | ⚠️ Docs thêm `INVESTIGATE` lẫn lộn `classification` | ⚠️ Xem chi tiết |
| `classification` | `latency_degradation`, `critical_service_down`, `noisy_or_ambiguous_alert`, `insufficient_context` | ❌ Docs dùng `CRITICAL_INCIDENT`, `LATENCY_DEGRADATION`, `INVESTIGATE` (UPPERCASE) | ❌ MISMATCH |
| `recommended_actions[].type` | `HUMAN_REVIEW`, `RUNBOOK_CHECK`, `ROLLBACK_CONSIDER`, `ESCALATE_OWNER`, `OBSERVE` | ❌ Không xuất hiện trong docs CDO | ⚠️ Không kiểm tra được |
| `APP_ENV` | `sandbox`, `staging`, `prod` | ✅ Khớp với `environment` | ✅ OK |
| `AI_MODE` | `rules`, `hybrid` | — | — |
| Lifecycle states (W12) | `OPEN`, `ACKNOWLEDGED`, `IN_REVIEW`, `RESOLVED`, `CLOSED` | — | — |
| Feedback values | `RCA_CONFIRMED`, `RCA_CORRECTED`, `OWNER_ACCEPTED`, `OWNER_REJECTED` | — | — |

---

## Chi tiết từng nhóm enum

---

### 1. `environment` — ✅ KHÔNG MISMATCH

**AI contract định nghĩa** (`telemetry-contract.md` L64, `observability-data-contract.md` L44):
```
prod | staging | sandbox
```

**CDO docs dùng** (`04_deployment_design.md` L127):
```
Dev | Staging | Prod  (nhưng mapping: sandbox → dev, prod → prod)
```

**`deployment-contract.md` L57:**
```
APP_ENV = sandbox | staging | prod
```

> ✅ Nhất quán. Đây là lowercase enum phía AI, env label phía infra thì capitalize nhưng không impact API contract.

---

### 2. `alert.severity` — ⚠️ CASE MISMATCH

**AI contract định nghĩa** (`telemetry-contract.md` L81):
```
critical | high | medium | low | unknown
```
*(lowercase)*

**CDO docs E2E_validate dùng** (`9_1_critical_incident_scenario.md` L271, `9_2_latency_degradation_scenario.md` L219):
```json
"severity": "CRITICAL"
"severity": "MEDIUM"
"severity": "HIGH"
```
*(UPPERCASE)*

**Mức độ rủi ro:** ⚠️ MEDIUM  
- Nếu CDO build parser expecting `CRITICAL` mà AI trả về `critical` → field không match, Slack/Jira template lỗi.
- Cần thống nhất 1 convention (khuyến nghị: UPPERCASE vì response field `status` đã dùng UPPERCASE).

**Nơi bị ảnh hưởng:**
- [`9_1_critical_incident_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_1_critical_incident_scenario.md#L271) — response mẫu `"severity":"CRITICAL"`
- [`9_2_latency_degradation_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_2_latency_degradation_scenario.md#L219) — response mẫu `"severity":"MEDIUM"`
- [`ai-api-contract.md`](file:///e:/x-brain/W8/Triage-Hub/ai-api-contract.md#L80) — request body `"severity": "high"` (lowercase)

---

### 3. `status` (response) — ✅ Nhất quán (nhưng cần chú ý)

**AI contract định nghĩa** (`ai-api-contract.md` L199-L204):
```
DIAGNOSED | INVESTIGATE | INSUFFICIENT_CONTEXT | UNSAFE_SUGGESTION_BLOCKED
```

**CDO docs dùng** (`9_3_false_positive_scebario.md` L276-L282):
```json
"classification": "INVESTIGATE"
```

> ⚠️ Lưu ý: `INVESTIGATE` là giá trị của field `status`, KHÔNG phải `classification`. Trong test case 9.3, CDO dùng `classification: INVESTIGATE` — sai field name.

**Nơi cần sửa:**
- [`9_3_false_positive_scebario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_3_false_positive_scebario.md#L276) — response mẫu dùng `classification: INVESTIGATE` → phải là `status: INVESTIGATE` + `classification: noisy_or_ambiguous_alert`

---

### 4. `classification` — ❌ MISMATCH NGHIÊM TRỌNG

**AI contract định nghĩa** (`ai-api-contract.md` L210-L215, skeleton behavior):
```
insufficient_context
critical_service_down
latency_degradation
noisy_or_ambiguous_alert
```
*(snake_case, lowercase)*

**CDO docs E2E_validate dùng:**

| File | Giá trị CDO dùng | Giá trị AI contract đúng |
|---|---|---|
| `9_1_critical_incident_scenario.md` L269 | `"classification":"CRITICAL_INCIDENT"` | `critical_service_down` |
| `9_2_latency_degradation_scenario.md` L217 | `"classification":"LATENCY_DEGRADATION"` | `latency_degradation` |
| `9_3_false_positive_scebario.md` L276 | `"classification":"INVESTIGATE"` | `noisy_or_ambiguous_alert` (+ `status: INVESTIGATE`) |

**Mức độ rủi ro:** ❌ HIGH — Critical mismatch  
- Đây là 3 scenario E2E chính của demo capstone.
- CDO build integration test với expected value `CRITICAL_INCIDENT` nhưng AI engine sẽ trả về `critical_service_down` → **Test sẽ FAIL trong buổi chấm T5.**
- `INVESTIGATE` trong field `classification` là sai hoàn toàn theo contract (`INVESTIGATE` là giá trị của `status`).

---

### 5. `recommended_actions[].type` — ⚠️ KHÔNG XUẤT HIỆN TRONG CDO DOCS

**AI contract định nghĩa** (`ai-api-contract.md` L188-L194):
```
HUMAN_REVIEW | RUNBOOK_CHECK | ROLLBACK_CONSIDER | ESCALATE_OWNER | OBSERVE
```

**CDO docs:** Không có test case nào kiểm tra field `recommended_actions[].type`.  
→ Rủi ro: CDO chưa biết cách parse/render các action type này trong Slack Block Kit.

---

### 6. `APP_ENV` env var — ✅ Nhất quán

**AI contract** (`deployment-contract.md` L57):
```
APP_ENV = sandbox | staging | prod
```
Phù hợp với `environment` enum trong request body.

---

### 7. `AI_MODE` env var — chỉ trong deployment contract

**AI contract** (`deployment-contract.md` L59):
```
AI_MODE = rules | hybrid
```
Không có trong CDO docs. Không gây mismatch API nhưng CDO cần biết khi cấu hình ECS task definition.

---

## Bảng tổng hợp mismatch cần fix trước T5

| # | Enum / Field | Contract (đúng) | CDO docs (sai) | File cần sửa | Mức độ |
|---|---|---|---|---|---|
| M1 | `classification` | `critical_service_down` | `CRITICAL_INCIDENT` | `9_1_critical_incident_scenario.md` | ❌ HIGH |
| M2 | `classification` | `latency_degradation` | `LATENCY_DEGRADATION` | `9_2_latency_degradation_scenario.md` | ❌ HIGH |
| M3 | `classification` | `noisy_or_ambiguous_alert` | `INVESTIGATE` | `9_3_false_positive_scebario.md` | ❌ HIGH |
| M4 | `status` vs `classification` | `status: INVESTIGATE` | `classification: INVESTIGATE` | `9_3_false_positive_scebario.md` | ❌ HIGH |
| M5 | `severity` case | `critical` (lowercase) | `CRITICAL` (UPPERCASE) | `9_1_*.md`, `9_2_*.md` | ⚠️ MEDIUM |

---

## Khuyến nghị fix

### Fix M1, M2, M3, M4 (classification values)
Cập nhật expected response trong 3 file E2E scenario:

**`9_1_critical_incident_scenario.md`** — sửa response mẫu:
```diff
- "classification":"CRITICAL_INCIDENT",
- "severity":"CRITICAL",
+ "classification":"critical_service_down",
+ "severity":"critical",
+ "status":"DIAGNOSED",
```

**`9_2_latency_degradation_scenario.md`** — sửa response mẫu:
```diff
- "classification":"LATENCY_DEGRADATION",
- "severity":"MEDIUM",
+ "classification":"latency_degradation",
+ "severity":"medium",
+ "status":"DIAGNOSED",
```

**`9_3_false_positive_scebario.md`** — sửa response mẫu:
```diff
- "classification":"INVESTIGATE",
+ "classification":"noisy_or_ambiguous_alert",
+ "status":"INVESTIGATE",
```

### Fix M5 (severity case)
**Quyết định cần AI team chốt:** dùng lowercase (theo contract) hay UPPERCASE?

> **Khuyến nghị:** thống nhất UPPERCASE cho toàn bộ enum value trong response body (vì `status`, `recommended_actions[].type` đều đang dùng UPPERCASE). Nếu chọn UPPERCASE thì AI team cần update `telemetry-contract.md` L81 thành `CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN`.

---

## Files cần xem lại

| File | Vấn đề |
|---|---|
| [`9_1_critical_incident_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_1_critical_incident_scenario.md) | `classification`, `severity` case |
| [`9_2_latency_degradation_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_2_latency_degradation_scenario.md) | `classification`, `severity` case |
| [`9_3_false_positive_scebario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_3_false_positive_scebario.md) | `classification` sai field, sai giá trị |
| [`ai-api-contract.md`](file:///e:/x-brain/W8/Triage-Hub/ai-api-contract.md) | Source of truth — không cần sửa |
| [`telemetry-contract.md`](file:///e:/x-brain/W8/Triage-Hub/telemetry-contract.md) | Cần thống nhất severity case |

---

## Phần Topology — Mismatch bổ sung

---

### T1. `environment` enum vs CDO infra env naming — ❌ MISMATCH (naming conflict)

**AI contract định nghĩa** (tất cả 4 contracts):
```
prod | staging | sandbox
```

**CDO docs infra** ([`04_deployment_design.md`](file:///e:/x-brain/W8/Triage-Hub/docs/reports/04_deployment_design.md#L127-L131)):
```
Dev | Staging | Prod
```

**Vấn đề:** CDO dùng `Dev` là tên environment infra nhưng AI contract không có `dev` — chỉ có `sandbox`. Mapping hiện tại:

| CDO infra env | AI contract env | Có mapping rõ ràng? |
|---|---|---|
| `Dev` | `sandbox` | ❌ Không được document |
| `Staging` | `staging` | ✅ Khớp |
| `Prod` | `prod` | ✅ Khớp |

**Nơi bị ảnh hưởng:**
- [`04_deployment_design.md`](file:///e:/x-brain/W8/Triage-Hub/docs/reports/04_deployment_design.md#L129) — env bảng dùng `Dev`
- [`04_deployment_design.md`](file:///e:/x-brain/W8/Triage-Hub/docs/reports/04_deployment_design.md#L39) — `dev/terraform.tfstate`
- [`deployment-contract.md`](file:///e:/x-brain/W8/Triage-Hub/deployment-contract.md#L57) — `APP_ENV = sandbox | staging | prod`

**Rủi ro:** Khi CDO gửi request với `"environment": "dev"` (từ infra config) → AI API sẽ reject `400` vì `dev` không nằm trong enum cho phép.

**Fix:** Thêm dòng mapping vào `04_deployment_design.md`:
```markdown
> Lưu ý: CDO infra environment `Dev` map sang AI contract value `sandbox`.
> Khi gọi AI API, field `environment` phải dùng `sandbox` (không phải `dev`).
```

---

### T2. Alert endpoint path — ❌ MISMATCH

**AI contract định nghĩa** ([`ai-api-contract.md`](file:///e:/x-brain/W8/Triage-Hub/ai-api-contract.md#L46)):
```
POST /v1/triage
```

**CDO E2E docs dùng** ([`9_1_critical_incident_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_1_critical_incident_scenario.md#L63), [`9_2_latency_degradation_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_2_latency_degradation_scenario.md#L58-L60)):
```
POST /v1/alerts
```

**Mức độ rủi ro:** ❌ HIGH — Đây là mismatch endpoint path trực tiếp.
- Contract AI định nghĩa endpoint nhận normalized incident context là `POST /v1/triage`.
- CDO test scenarios (cả 3 file) gọi vào `POST /v1/alerts` — endpoint này **không tồn tại** trong AI API contract.
- E2E test sẽ trả `404` toàn bộ.

**Giải thích kiến trúc:** Trong contract, luồng là:
```
CDO detect alert → CDO calls POST /v1/triage (với full context bundle)
```
Không có endpoint `/v1/alerts` riêng. CDO phải build context bundle trước rồi gọi `/v1/triage` — không phải gửi raw alert vào `/v1/alerts`.

**Fix cần làm:** Cập nhật cả 3 file E2E scenario:
```diff
- POST /v1/alerts
+ POST /v1/triage
```
Và CDO cần thêm bước build context bundle trước khi gọi `/v1/triage`.

---

### T3. ECS cluster name trong E2E chaos test — ⚠️ Minor

**AI contract** ([`deployment-contract.md`](file:///e:/x-brain/W8/Triage-Hub/deployment-contract.md#L36-L37)):
```
Cluster: tf-1-aiops-cluster
Service: tf1-ai-triage-engine
```

**CDO E2E chaos test** ([`9_1_critical_incident_scenario.md`](file:///e:/x-brain/W8/Triage-Hub/docs/E2E_validate/9_1_critical_incident_scenario.md#L188-L194)):
```bash
aws ecs update-service \
  --cluster prod \
  --service api-service
```

**Vấn đề:** CDO dùng `--cluster prod` và `--service api-service` (placeholder generic) thay vì tên thật từ deployment contract. Khi chạy chaos test thật sẽ fail vì cluster không tồn tại.

---

### Bảng tổng hợp mismatch TOPOLOGY

| # | Vấn đề | Contract | CDO docs | Mức độ |
|---|---|---|---|---|
| T1 | `environment` naming | `sandbox` | `Dev` (không map) | ❌ HIGH |
| T2 | Endpoint path | `POST /v1/triage` | `POST /v1/alerts` | ❌ HIGH |
| T3 | ECS cluster name | `tf-1-aiops-cluster` | `prod` (placeholder) | ⚠️ LOW |

---

## Tổng hợp toàn bộ (M + T)

| ID | Loại | Mức độ | Vấn đề | Fix ở đâu |
|---|---|---|---|---|
| M1 | classification | ❌ HIGH | `CRITICAL_INCIDENT` → `critical_service_down` | CDO E2E `9_1_*.md` |
| M2 | classification | ❌ HIGH | `LATENCY_DEGRADATION` → `latency_degradation` | CDO E2E `9_2_*.md` |
| M3 | classification | ❌ HIGH | `INVESTIGATE` → `noisy_or_ambiguous_alert` | CDO E2E `9_3_*.md` |
| M4 | field confusion | ❌ HIGH | `classification: INVESTIGATE` → `status: INVESTIGATE` | CDO E2E `9_3_*.md` |
| M5 | severity case | ⚠️ MEDIUM | lowercase vs UPPERCASE chưa thống nhất | AI team chốt, cả 2 bên sửa |
| T1 | environment | ❌ HIGH | `dev` không có trong contract enum | CDO `04_deployment_design.md` |
| T2 | endpoint path | ❌ HIGH | `/v1/alerts` ≠ `/v1/triage` | CDO E2E cả 3 scenario file |
| T3 | ECS name | ⚠️ LOW | Placeholder cluster name | CDO E2E `9_1_*.md` |
