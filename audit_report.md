# Audit Report — Capstone AIOps Triage Hub

**Ngày:** 2026-06-30 · **Auditor:** senior staff / security+perf · **Scope:** `Triage-Hub` (CDO-09) + `xBrain-capstone2` (AI team)
**Ràng buộc:** Code team AI **chỉ report, không sửa** (theo yêu cầu chủ repo). Findings actionable tập trung CDO-owned.

---

## 1. Tóm tắt điều hành

| Mức độ | Số lượng |
|---|---:|
| Blocker | 0 |
| High | 1 |
| Medium | 6 |
| Low | 5 |
| Drift / Note | 2 |

**Phương pháp:** đọc thực tế từng file + verify trên cluster live (EKS `triage-hub-eks`) + `ruff`. Không suy đoán.

### 5 việc nên sửa trước
1. **[High] Duplicate Jira ticket** — `notify-dispatcher` idempotency không atomic (read-then-PutItem). SQS at-least-once → tạo trùng ticket.
2. **[Medium] SQS không mã hoá at-rest** — message chứa dữ liệu tenant/incident. Bật `sqs_managed_sse_enabled` (1 dòng).
3. **[Medium] Node role gánh quyền cluster-autoscaler trên `*`** — mọi pod trên node thừa hưởng `SetDesiredCapacity`/`TerminateInstance`.
4. **[Medium] Slack mention injection** — text RCA/evidence từ AI render vào Slack chưa escape (`<!channel>`/`<@U>`).
5. **[Medium] LB Controller dùng `ElasticLoadBalancingFullAccess`** — rộng hơn official least-priv policy.

> **Đã sửa trong session này (commit `737cd51`, chưa push):** TargetGroupBinding ARN stale + KEDA `identityOwner` (403 SQS). Xem mục 6.

---

## 2. Bảng phát hiện (sắp theo mức độ)

| # | Mức độ | Hạng mục | File:dòng | Mô tả | Tác động | Cách sửa | Tin cậy |
|---|---|---|---|---|---|---|---|
| 1 | **High** | Resilience/Correctness | `app/notify-dispatcher/index.js:692-719`, `:235-251` | "Idempotency check" = `getJiraMapping` (read) → nếu trống thì `createJiraTicket` → `updateJiraMapping` (PutItem **vô điều kiện**). Không atomic. | SQS at-least-once + xử lý đồng thời 2 message cùng `incident_id` → **2 Jira ticket trùng**. | `updateJiraMapping` dùng `ConditionExpression: attribute_not_exists(PK)`; bắt `ConditionalCheckFailedException` → re-read mapping, skip create. | Cao |
| 2 | Medium | Bảo mật (encryption) | `infra/modules/sqs/main.tf:6-30` | Cả main queue lẫn DLQ **không set** `sqs_managed_sse_enabled`/`kms_master_key_id`. | Message (alert labels, description, RCA, evidence) lưu plaintext at-rest. | Thêm `sqs_managed_sse_enabled = true` cho cả `dlq` và `this`. | Cao |
| 3 | Medium | Bảo mật (IAM) | `infra/modules/eks/main.tf:93-116` | Policy cluster-autoscaler (`autoscaling:SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup`, `Resource="*"`) gắn vào **node instance role**. | Mọi pod trên node (kể cả pod bị compromise) có thể scale/terminate ASG. Cũng là lý do KEDA fallback node-role. | Tách IRSA riêng cho cluster-autoscaler; scope bằng condition `autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled=true`. | Cao |
| 4 | Medium | Bảo mật (injection) | `app/notify-dispatcher/index.js:411,418,433` | `suspected_root_cause.summary`, `evidence[]`, `recommended_actions[]` render vào Slack mrkdwn **không escape** (chỉ assignee/reason được escape). | Text AI/alert chứa `<!channel>`, `<!here>`, `<@Uxxx>` → mass-mention / giả mạo link. | Bọc `escapeSlackMrkdwn()` cho cả 3 field. | Cao |
| 5 | Medium | Bảo mật (IAM) | `infra/environments/sandbox/main.tf:642-645` | LB Controller IRSA attach managed policy `ElasticLoadBalancingFullAccess`. | Rộng hơn nhiều so với nhu cầu; full quyền ELB. | Dùng official AWS Load Balancer Controller IAM policy (least-priv, có condition theo tag). | Cao |
| 6 | Medium | Resilience | `app/notify-dispatcher/index.js:592-624` | `postToSlack` gọi `fetch` trực tiếp, **không** qua `fetchWithRetry` (khác với các call Jira). | Slack 429/5xx không retry → mất notification. | Route qua `fetchWithRetry`; xử lý `result.ok=false` cho 429. | Cao |
| 7 | Medium | Resilience | `app/alert-ingest/index.js:72-121` | Vòng lặp alert không có try/catch per-item. `sendSeedToSqs`/`getTenantConfig` throw → cả batch fail. | 1 alert lỗi → toàn bộ webhook trả 502, alert đã accept không được báo. | try/catch quanh thân loop, đẩy item lỗi vào `dropped` với reason. | Cao |
| 8 | Low-Med | Hiệu năng | `app/alert-ingest/index.js:114` | `await sendSeedToSqs(seed)` tuần tự trong loop (N alert = N round-trip nối tiếp). | Latency tăng tuyến tính theo số alert/batch. | `Promise.all` hoặc `SendMessageBatch` (tối đa 10/batch). | Cao |
| 9 | Low-Med | Bảo mật (log) | `app/alert-ingest/index.js:312`, `:430-437` | Log full `messageBody` (incident seed) ; `redactHeaders` chỉ che `x-api-key`, **không che** `Authorization`. | CloudWatch lưu payload + header nhạy cảm. | Log metadata-only; thêm `authorization` vào danh sách redact. | Cao |
| 10 | Low | Chất lượng (dead code) | `app/jira-dispatcher/index.js:98-112` & `:231-250` | Hàm `updateSlackMessage` khai báo **2 lần**; bản đầu (không try/catch) bị bản sau ghi đè (hoisting). | Dead code, gây nhầm lẫn. | Xoá bản dòng 98-112. | Cao |
| 11 | Low | Correctness | `app/jira-dispatcher/index.js:174` | `assignJiraTicket` đọc `response.ok` nhưng `fetchWithRetry` có thể trả `null` (hết retry trên 5xx). | `TypeError: Cannot read 'ok' of null` (bị catch nhưng message sai). | Guard `if (!response || !response.ok)` (như `createJiraTicket:216` đã làm). | Cao |
| 12 | Low | Infra (supply-chain) | `app/ai-engine/Dockerfile:2,8` | Base image `python:3.12-slim` pin theo tag, không pin digest. | Tag có thể đổi → build không tái lập, rủi ro supply-chain. | Pin `python:3.12-slim@sha256:...`. | Trung bình |

---

## 3. Drift giữa 2 sub-project

| # | Hạng mục | Bằng chứng | Ghi chú (report-only, không sửa code AI) |
|---|---|---|---|
| D1 | Engine vendored lệch handoff | `Triage-Hub/.../ai-engine/app/main.py` = **917 dòng** vs `xBrain-capstone2/.../engine-skeleton/app/main.py` (ac21f60) = **844 dòng** | Bản CDO copy không khớp commit handoff mới nhất (`ac21f60`). CDO cần quyết: re-sync hay giữ bản hiện tại. |
| D2 | Thiếu AgentCore image | CDO **không có** `agentcore_investigator/`; AI có (`Dockerfile`, `main.py`, `requirements.txt`) | Handoff `11_v1_0_0_handoff.md` yêu cầu **2 image** cho production AgentCore path. Hiện CDO chạy deterministic-mode (`ENABLE_AGENTCORE_LLM=false` trong `rollout.yaml`) → chấp nhận được cho demo, nhưng là "degraded mode" theo handoff. |

---

## 4. Quick wins (<15 phút)

- **#2** SQS SSE: thêm `sqs_managed_sse_enabled = true` (2 resource).
- **#10** Xoá hàm `updateSlackMessage` trùng (dòng 98-112).
- **#11** Null-guard trong `assignJiraTicket`.
- **#4** Bọc `escapeSlackMrkdwn` cho RCA/evidence/actions.
- **#9** Thêm `authorization` vào `redactHeaders`.
- **#12** Pin base image digest.

---

## 5. Điểm TỐT (đã đạt chuẩn — không cần sửa)

- **S3:** SSE AES256 + `block_public_*` đủ 4 cờ (`modules/s3/main.tf:24-40`).
- **DynamoDB:** PITR + SSE bật (`modules/dynamodb/main.tf:21-26`).
- **Terraform state lock:** backend S3 `use_lockfile = true` (TF 1.10+, không cần DynamoDB) (`provider.tf`).
- **CI/CD:** OIDC `id-token: write`, default `contents: read`, không static AWS key; gitleaks scan (`ci-app.yml`).
- **terraform-destroy:** guardrail confirm-string `destroy-sandbox` + GitHub environment gate + chỉ cho `sandbox` (`terraform-destroy.yml`).
- **Slack callback:** verify HMAC `timingSafeEqual` + chống replay 300s (`jira-dispatcher/index.js:136-156`).
- **Slack channel:** validate regex chống inject channel tuỳ ý (`notify-dispatcher/index.js:742`).
- **Dockerfile:** multi-stage, non-root uid 1000, healthcheck (`ai-engine/Dockerfile`).
- **requirements.txt:** pin đầy đủ version. `ruff` sạch trên AI app.
- **Secrets:** không có live credential/token hardcode trong file tracked; `.tfvars` gitignored.

---

## 6. Đã xử lý trong session (commit `737cd51`, **CHƯA push develop**)

| Lỗi live (verify trên `triage-hub-eks`) | Fix |
|---|---|
| `TargetGroupBinding/tf1-api-tgb` = OutOfSync/Missing (ARN trỏ TG cũ `...c943f57c5bea0682`) | Overlay → ARN thật `...7421cf8ee2e843ec`; thêm `aws_ssm_parameter` để CI auto-patch lần sau |
| `ScaledObject/tf1-worker-scaler` = Degraded (KEDA 403 `sqs:GetQueueAttributes`) | `identityOwner: operator` → `pod` (dùng IRSA `tf1-worker-sa` đã có sẵn quyền) |

→ Cluster live vẫn còn 2 lỗi này tới khi `737cd51` lên `develop` (ArgoCD selfHeal track `develop`).

---

## 7. Ngoài scope CDO (AI team tự xử)

- `SERVICE_AUTH_TOKEN` fail-open nếu env không set (`engine-skeleton/app/main.py`) — đã note ở các session trước, thuộc AI team.
- AI app `ruff` sạch, không có finding lint.
