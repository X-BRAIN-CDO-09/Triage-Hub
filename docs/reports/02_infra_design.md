# Infrastructure Design - Task force <N> · CDO <M>

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T3-T4) → Final (W11 T6 Pack #1) → Updated (W12 T4 Pack #2)
     Word target: 1500-2500 từ -->

## 1. Architecture diagram (Owner: Tiến)

![Architecture Diagram](../assets/infra-architecture.png)

*Caption: <giải thích flow + tại sao layout này>*

## 2. Component table (Owner: Tiến)

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| Compute | <Lambda / Fargate / EKS> | <why> | $X |
| API entry | <API GW / ALB> | <why> | $X |
| Database | <DynamoDB / RDS / Aurora> | <why> | $X |
| Storage | <S3 + tier> | <why> | $X |
| Event bus | <EventBridge / Kinesis / SQS> | <why> | $X |
| Observability | <CloudWatch / Grafana> | <why> | $X |

## 3. Differentiation angle deep-dive (Owner: Tiến)

### 3.1 Why this angle?

<!-- Tại sao chọn serverless-first / K8s-heavy / managed-services / hybrid? -->

### 3.2 Vượt trội ở đâu (số liệu)

| Axis | My number | Competing angle estimate |
|---|---|---|
| Cost / tenant / month | $X | $Y |
| P99 latency | Xms | Yms |
| Ops overhead (hr/week) | X | Y |
| Time to onboard tenant | X min | Y min |

### 3.3 Weakness chấp nhận

<!-- Honest về trade-off. Reviewer thích honesty hơn là "everything is great" -->

## 4. Multi-tenant approach (Owner: Tiến)

### 4.1 Tenant model

- **Tenant ID format**: UUID v4
- **Header**: `X-Tenant-Id` mandatory all API calls
- **Subscription tiers**: basic / pro / enterprise (impact: quota, feature flags)

### 4.2 Isolation pattern

- **Data isolation**: <silo (per-tenant DB) / pool (shared with row-level) / bridge (hybrid)> - justify
- **Compute isolation**: <shared / per-tenant container / per-tenant account>
- **Why this pattern**: <cost vs isolation strength trade-off>

### 4.3 Tenant onboarding flow

```
1. POST /platform/v1/tenants (tenant_name, contact, tier)
2. IaC trigger (Terraform module or Step Function)
3. Provision: IAM role + namespace + DB schema + initial config
4. Smoke test
5. Webhook callback: tenant ready (< 30 min total)
```

### 4.4 Noisy neighbor mitigation

- **Per-tenant quota**: <vd 1000 req/min / tenant>
- **Rate limiting**: API Gateway usage plan / custom Lambda
- **Resource reservation**: <vd dedicated Fargate task for enterprise tier>

## 5. Alternatives considered (Owner: Tiến)

### 5.1 Compute layer

- **Option A**: Lambda + API GW - Pros: cost-tight, ops-light · Cons: cold start, 15min limit
- **Option B**: ECS Fargate + ALB - Pros: longer runtime, predictable latency · Cons: higher fixed cost
- ✅ **Chosen**: ... - Reason: ...

### 5.2 Database

- **Option A**: ... 
- **Option B**: ...
- ✅ **Chosen**: ...

## 6. Scaling strategy (Owner: Tiến)

- **Vertical**: <CPU/memory bump triggers>
- **Horizontal**: <auto-scaling rules>
- **Triggers**: target CPU 70% / request count / queue depth

## 7. Failure modes + recovery (Owner: Tiến)

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| Single task crash | ECS health check | Auto-restart | < 60s | 0 |
| AZ outage | CloudWatch alarm | Multi-AZ failover | < 5min | < 1min |
| DB primary fail | RDS event | Read replica promotion | < 5min | < 1min |
| Region outage | External monitor | Manual region switch (post-capstone) | TBD | TBD |

## 8. AI Engine Runtime Module (Owner: Thi)

<!-- Scope: hosting + runtime của AI Engine trên EKS (KAN-203/204/205).
     Engine logic/app do AI team own; phần này chỉ cover infra host + deploy + scale + tích hợp. -->

### 8.1 Scope & boundary

Module này chịu trách nhiệm **host AI Engine của AI team trên Amazon EKS**, không sở hữu logic RCA/prompt (thuộc AI team). Phạm vi:

- **KAN-203** Containerize + sign image engine.
- **KAN-204** Deploy engine lên EKS qua GitOps.
- **KAN-205** Auto scaling engine theo tải.

Engine chạy **private hoàn toàn** (no internet route); mọi egress đi qua VPC Endpoint, riêng SaaS (Slack/Jira) qua Lambda Dispatcher + NAT (đường ngoại lệ).

### 8.2 Architecture

![AI Engine Architecture](../assets/aiengine-architecture.png)


*Caption: Engine gồm 2 Deployment (tf1-api + tf1-worker) trên EKS. Worker consume incident_seed từ buffer, gọi tf1-api `/v1/triage` đồng bộ qua Internal ALB, engine query context read-only + Bedrock/AgentCore, ghi audit immutable, rồi đẩy payload Slack/Jira ra Dispatch Queue cho Lambda Dispatcher gửi đi.*

### 8.3 Components & ownership

| Component | Service | Vai trò trong module | Owner |
|---|---|---|---|
| Engine compute | EKS managed node group | host tf1-api + tf1-worker | CDO |
| API entry | Internal ALB (private, TLS 1.2+, 443→8080) | sync `/v1/triage` | CDO |
| Image registry | ECR private | image Cosign-signed | CDO |
| Engine app | container (FastAPI + worker) | logic RCA/triage | AI team |
| Secrets inject | Secrets Manager + ESO | Bedrock/AgentCore creds | CDO |
| Audit | S3 Object Lock | log mọi AI decision (immutable) | CDO |

### 8.4 Build & supply-chain (KAN-203)

Pipeline đóng gói engine của AI team thành image an toàn:

`Dockerfile (multi-stage, distroless, non-root, EXPOSE 8080)` → `docker build` → `Trivy scan (fail on HIGH/CRITICAL)` → `Cosign sign` → `push ECR private` → `policy-controller verify chữ ký trước khi pod chạy`.

→ Không image nào chạy mà chưa quét lỗ hổng + chưa ký. Tận dụng stack từ lab `aws-sercurity`.

### 8.5 Deploy on EKS (KAN-204)

- Deploy qua **ArgoCD (app-of-apps, GitOps)** + **Argo Rollouts** canary 10→50→100%, auto-rollback on abort.
- **2 Deployment** namespace-per-tenant:
  - `tf1-api` (FastAPI): expose `/v1/triage` + report API, readiness/liveness `/healthz:8080`.
  - `tf1-worker`: consume incident_seed, gọi tf1-api nội bộ (sync), persist + audit, emit ticket/Slack payload.
- **IRSA least-privilege** (scoped ARN): `bedrock:InvokeModel`, `agentcore:InvokeAgent`, `secretsmanager:GetSecretValue`, `s3:PutObject`, `dynamodb:*` (table riêng).
- **In-cluster security:** Gatekeeper (OPA: block root, required resources, deny hostNetwork, max replicas), RBAC, NetworkPolicy deny-all, Pod Security `restricted`.

### 8.6 Auto scaling (KAN-205)

- **HPA**: Policy 1 — CPU 70%; Policy 2 — custom metric ALB request/pod = 100 (qua Prometheus Adapter). Min 2 / Max 6 pods (theo `deployment-contract.md:45`).
- **Cluster Autoscaler**: thêm/bớt node khi pod pending. Min 2 / Max 10 nodes.
- **SQS Buffer** đệm alert bursty trong lúc HPA kịp scale.

### 8.7 AI endpoint integration

- Endpoint: **`POST /v1/triage`** (sync) + **`GET /v1/reports`** + **`GET /v1/reports/{id}`**.
- Input: `incident_seed.v1` (lightweight — không chứa full metrics/logs).
- Output: classification, severity, confidence, suspected_root_cause, recommended_actions, anomaly_evidence, investigation_summary, audit_id, Slack/Jira payload, report URL.
- SLA: engine gọi **đồng bộ qua Internal ALB**, p99 < 2s (theo `ai-api-contract.md:207`). SQS chỉ buffer intake/dispatch, **không** nằm trong request path sync.

### 8.8 Context access (read-only, CDO-exposed)

Engine **tự lấy context** (không nhận full telemetry trong seed). CDO expose read-only:

- Metrics (Prometheus-compatible, delay < 60s), Logs (Loki-compatible, delay < 120s), Deploy metadata, Ownership/runbook mapping.
- Mọi query **scope theo `tenant_id / environment / service / time-window`**, bounded p95 < 2s.

### 8.9 Egress & network model

- Engine **no internet route**. AWS service đi qua VPC Endpoint: Bedrock, AgentCore, Secrets Manager, SQS, CloudWatch Logs, ECR (api/dkr), STS (Interface); S3, DynamoDB (Gateway).
- SaaS (Slack/Jira) **không gọi trực tiếp từ engine** — engine emit payload → SQS Dispatch Queue → Lambda Dispatcher (có NAT) → Slack/Jira. `SLACK_WEBHOOK_URL` giữ ở dispatcher, không ở engine.

### 8.10 Secrets

Inject qua **ESO** (External Secrets Operator) từ Secrets Manager → K8s Secret. No hardcode, no `valueFrom` tĩnh. Engine giữ: Bedrock/AgentCore credentials. (Webhook Slack thuộc dispatcher.)

### 8.11 Failure modes & resilience

| Failure | Detection | Recovery |
|---|---|---|
| Pod crash | liveness probe | K8s restart (<60s) |
| Node fail | node health | Cluster Autoscaler thay node |
| AI 503/timeout | app metric | fallback rule-based alert (ensure availability) |
| Bedrock throttle | app metric | exp backoff → DLQ |
| Malformed seed | schema validate | DLQ, no silent drop |
| Alert spike | queue depth | SQS buffer + HPA |

### 8.12 Acceptance mapping (AI team checklist)

- Latency incident → engine trả latency report ✓
- Critical service-down → service-down actions ✓
- Noisy alert → observe / human-review only ✓
- Invalid seed → DLQ/error path, no silent drop ✓
- Context chỉ trong scope tenant/service/time-window ✓
- `/v1/triage` direct sample requests chạy ✓
## 9. Slack Alert & Interactive Assignment Architecture (Owner: Hoàng)

![Slack Architecture](../assets/Slack-Integration.drawio.png)

### 9.1 Slack Interactive Flow
Hệ thống áp dụng kiến trúc **"AI Suggestion + Human-in-the-loop"** thay vì Auto-assign hoàn toàn để kiểm soát rủi ro phân công nhầm người. 
- **Notification Lambda**: Nhận `ticket_payload` từ AI, bóc tách `suggested_assignee` và tạo Slack Block Kit JSON có kèm nút **[Confirm & Assign]**.
- **API Gateway**: Đóng vai trò là Public Webhook Endpoint để nhận tín hiệu click chuột từ nền tảng Slack.
- **Callback Lambda**: Bóc tách event từ Slack, trích xuất `jira_issue_key` và gọi REST API của Jira để tự động gán việc cho nhân sự được đề xuất.

### 9.2 Component Deep-Dive
| Component | AWS Service | Purpose in Slack Flow |
|---|---|---|
| Slack Notifier | Lambda | Gửi tin báo sự cố 1 chiều lên Slack Channel |
| Slack Webhook | API Gateway | Nhận payload tương tác (POST request) từ người dùng Slack |
| Slack Callback | Lambda | Xử lý sự kiện bấm nút [Confirm & Assign] và gọi Jira API |
| Token Storage | Secrets Manager | Lưu trữ an toàn Bot Token (Slack) và API Token (Jira) |

### 9.3 Sequence Diagram
Sơ đồ trình tự xử lý luồng tương tác 2 chiều giữa con người, Slack và hệ thống Triage-Hub:

![Slack Sequence Diagram](../assets/slack-sequence.png)

### 9.4 Security & Authentication
Do API Gateway phải mở dạng Public (để Slack gọi vào), kiến trúc bảo mật áp dụng các lớp phòng thủ sau:
- **Slack Signature Verification:** API Gateway (hoặc Lambda Callback) sử dụng `Slack Signing Secret` (lưu tại Secrets Manager) để xác thực Header `X-Slack-Signature`. Chỉ những request xuất phát từ chính nền tảng Slack mới được phép thực thi.
- **Least-privilege IAM:** Hàm Lambda chỉ được cấp quyền tối thiểu: `secretsmanager:GetSecretValue` và quyền ghi log CloudWatch. Ngăn chặn triệt để rủi ro tấn công leo thang đặc quyền.

### 9.5 Edge Cases & Failure Recovery
Các tình huống ngoại lệ được thiết kế để đảm bảo luồng "Human-in-the-loop" không trở thành "điểm đứt gãy" (single point of failure):

| Rủi ro (Failure Mode) | Cách xử lý (Mitigation) |
|---|---|
| Người dùng bấm nút 2 lần liên tiếp (Double-click) | Slack Block Kit hỗ trợ cấu trúc tự động vô hiệu hóa nút sau khi click. Lambda cũng kiểm tra state của Jira trước khi gán. |
| Jira API sập (Downtime) | Lambda catch lỗi HTTP 5xx, trả về thông báo lỗi dạng ephemeral message cập nhật thẳng vào Slack để báo team assign tay. |
| Slack yêu cầu timeout 3s | API Gateway được cấu hình để phản hồi `200 OK` ngay lập tức về cho Slack. Logic gọi API Jira được Lambda xử lý bất đồng bộ, tránh lỗi Timeout hiển thị cho user. |

## 10. Jira Integration Layer (Owner: Phong)

### 10.1 Architecture

![Jira Integration Architecture](../assets/Jira-Integration.drawio.png)

Kiến trúc áp dụng nguyên tắc **Jira-First**: AI Engine gửi diagnosis payload qua API Gateway → EventBridge. `jira-dispatcher` consume event, tra cứu `account_id` do AI đề xuất từ DynamoDB, tạo Jira ticket, và **chỉ khi thành công** mới emit `slack.notify` event. `slack-dispatcher` không bao giờ gọi Jira. Khi Jira fail, payload được đưa vào SQS DLQ và `slack.fallback` event gửi raw text alert.

### 10.2 Sequence flow

![Jira Flow Sequence](../assets/Jira_flow.jpeg)

### 10.3 Component table

| Component | AWS Service | Rationale | Cost estimate |
|---|---|---|---|
| Compute | `jira-dispatcher` Lambda | Event-driven, pay-per-use, zero idle cost. Single-purpose function với <30s runtime, phù hợp Lambda. | Free Tier up to 1M req/month. ~$0.50/month ở 10k alerts. |
| Database | DynamoDB | Key-value lookup theo `tenant_id#email`. Không cần join, single-digit ms reads. Managed, auto-scaling. | On-demand. ~$0.25/GB-month. ~5KB per mapping × 50 tenants × 50 users = negligible. |
| Event Bus | EventBridge | Native Lambda target, 24h retry window, schema registry, event filtering. Giúp decouple dispatchers không cần custom middleware. | $1.00/million events. 2 events per alert (ingest + notify). |
| Queue | SQS (DLQ) | Dead-letter queue cho failed alerts. Max 14-day retention, redrive về Lambda để replay. | $0.40/million requests. DLQ nhận <1% traffic. |
| Security | Secrets Manager | Auto-rotation mỗi 30 days. Fine-grained IAM scope chỉ đọc cho Lambda. Encrypted at rest via KMS. | $0.40/secret/month + $0.05/10k API calls. Một secret cho Jira API token. |

### 10.4 Design rationale

#### 10.4.1 Why Jira-First

Hai competing patterns đã bị reject:

**Slack-First Chained Dependency** — `slack-dispatcher` tạo Jira ticket như side effect sau khi post Slack. Điều này coupling notification với ticketing: nếu Slack chậm, Jira creation bị stall. Nếu engineer acknowledge trước khi Jira tồn tại, audit trail bị phá vỡ. Slack API failure đồng nghĩa toàn bộ incident không được record.

**Blind Auto-Assignment** — AI-recommended owner được assign ngay lập tức không cần human confirmation. Nếu AI sai (deactivated user, wrong team, cross-tenant mapping), tickets languish trong wrong queue, làm tăng MTTA.

Jira-First coi Jira ticket là **single source of truth**. Ticket phải tồn tại trước khi bất kỳ notification nào được gửi. `issue_key` flow qua mọi subsequent event, tạo immutable chain: alert → ticket → notification → acknowledgement.

#### 10.4.2 Comparison with alternatives

| Axis | Jira-First | Slack-First | Blind Auto-Assign |
|---|---|---|---|
| Time to Route (MTTA) | ~45s (create 2s + post 1s + accept ~42s) | ~90s (post 1s + read 60s + create 2s + reassign) | ~30s nhưng ~25% wrong → effective MTTA gấp đôi |
| Wrong Assignment Rate | <3% (AI recommend, human verify, assign sau accept) | ~3% + ~10% nếu human acknowledge trước khi Jira tồn tại | ~25% (AI model accuracy ceiling ~75% cho team-owner prediction) |
| Silent Data Drop Rate | <0.1% (DLQ bắt mọi failure; fallback Slack notify engineer) | ~8% (Slack delivered, Jira never created → không permanent record) | ~25% (ticket created, assigned wrong, tồn đọng) |

*Numbers là estimated baselines cho capscope, cần validate trong W12 eval.*

#### 10.4.3 Accepted weakness

**Stale DynamoDB mapping.** Background sync chạy mỗi 5 phút. Nếu engineer mới join trước khi sync chạy, `jira-dispatcher` không thể resolve email → Jira `account_id`.

- Ticket luôn được tạo ở trạng thái **unassigned** bất kể mapping state. Human-in-the-loop qua Slack là primary path, không phải DynamoDB lookup.
- DynamoDB miss không phải failure — "Accept" flow sẽ prompt manual input. Estimated <2% initial assignments.
- Sync interval có thể giảm xuống 1 minute với negligible cost (~120 extra Jira API calls/day).

Đánh đổi: chấp nhận <5 phút staleness window để lấy operational simplicity, thay vì xây streaming CDC pipeline từ Jira (webhook listener, retries, callback auth). Pragmatic cho capscope và first production release.

### 10.5 Multi-tenant approach

Mọi request đều mang `X-Tenant-Id` header (UUID v4). API Gateway validate presence; Lambda enforce partition key scoping trong DynamoDB.

| Dimension | Pattern | Rationale |
|---|---|---|
| Compute | Shared | Một Lambda xử lý tất cả tenants. Cold start paid once. Không cross-tenant state trong memory — toàn bộ state ở DynamoDB. |
| Data | Pooled (row-level) | Một DynamoDB table với Partition Key = `tenant_id#email`. IAM condition `ddb:LeadingKeys` enforce tenant scope ở policy level — fail-closed ngay cả khi application code có bug. |
| Network | Shared | Một VPC, một subnet group. Không cần per-tenant ENI hay NAT Gateway. |

Silo isolation (per-tenant table) tốn ~$6.50/month cho 50 tables vs ~$0/month idle cho một pooled table — 13× chi phí, không có measurable security benefit nhờ IAM guardrail.

### 10.6 Audit trail

Mọi AI decision đều được link với Jira ticket để đảm bảo traceability:

- `issue_key` được dùng làm correlation ID trong tất cả EventBridge events và CloudWatch Logs structured logs.
- Jira ticket description field chứa `Correlation-ID` value trỏ về original `alert.ingested` event.
- AI diagnosis payload (root cause, confidence score, remediation steps, recommended `account_id`) được persist cùng event trong CloudWatch Logs, keyed bởi cùng correlation ID.
- Cho phép post-incident queries dạng: *"Show me the AI diagnosis that led to ticket INC-123."*

### 10.7 Failure modes & recovery

| Failure | Detection | Recovery | RTO | RPO |
|---|---|---|---|---|
| Jira API down (429/500) | Lambda catch HTTP >= 400. EventBridge retry exhausted (3 attempts), route to DLQ. | Payload ghi vào SQS DLQ kèm original `alert.ingested` envelope. `jira-dispatcher` emit `slack.fallback` → `slack-dispatcher` gửi raw alert text với "[JIRA DOWN]" prefix. DLQ redrive thủ công sau khi Jira recover. | < 60s (detection + fallback) | 0 (payload in DLQ) |
| AI recommend invalid/deactivated `account_id` | Jira trả 400 trên `PUT /assignee` — `"user does not exist"`. | `jira-dispatcher` catch 400, log vào CloudWatch. Ticket remain **unassigned**. `slack.notify` event chứa `assignee_status: "unassigned_invalid_user"`. Slack hiển thị "Assign Me" button → webhook callback để reassign cho current engineer. | < 30s | 0 (ticket created, chỉ assignment fail) |
| DynamoDB lookup timeout | Lambda metric `DynamoDB.GetItem` latency > 3s trigger CloudWatch alarm. Function catch `ProvisionedThroughputExceededException` hoặc timeout. | Ticket created unassigned. `slack.notify` chứa `assignee_status: "dynamodb_timeout"`. Slack hiển thị "⚠️ User mapping unavailable — please assign manually." | < 5s | 0 (assignment deferred to human) |

## Related documents

- [`03_security_design.md`](03_security_design.md) - Network Security §4 + IAM §5 + Data Security §6 expand on infra concerns
- [`04_deployment_design.md`](04_deployment_design.md) - IaC + CI/CD + GitOps cho infra này
- [`05_cost_analysis.md`](05_cost_analysis.md) - Per-tenant cost model based on this infra
- [`08_adrs.md`](08_adrs.md) - Infra architecture decisions
