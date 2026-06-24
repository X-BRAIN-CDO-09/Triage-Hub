# TF1 Triage Hub — Architecture Review & AI↔CDO Alignment

> Tổng hợp requirement (mentor + xbrain-learners + handoff AI) · reverse-engineer kiến trúc từ code/contract nhóm AI · đối chiếu diagram CDO · liệt kê điểm lệch **kèm evidence (file + dòng)**.
> Người review: CDO TF1 (Thi). Cập nhật: 2026-06-24.
> Nguồn AI: repo `xBrain-capstone2` tại `capstone/tf-1/ai/`. Nguồn CDO: repo `Triage-Hub`.

---

## 1. Dự án giải quyết gì

SaaS B2B, 8 on-call engineer, 50+ alert/tuần, mỗi alert tốn 30-60 phút dig log thủ công → MTTR tăng, burnout. **Triage Hub** tự động: alert → gom context → AI chẩn đoán root cause + đề xuất action → tạo Jira ticket + ping Slack. Engineer chỉ **confirm + act**. **No auto-remediation** (human-in-the-loop bắt buộc).

**Success metrics (hard-req):** MTTA ↓≥50%, MTTR ↓≥30%; 3 scenario E2E (latency-degradation, critical-service-down, noisy-false-alert); confidence correlate accuracy; audit mọi AI decision; multi-tenant isolation 0 leak; single-region `us-east-1`; synthetic data.

---

## 2. Kiến trúc THẬT (reverse-engineer từ code + contract nhóm AI)

```
CDO detector → incident seed
      ↓
[AIOps Worker]  (AI team — app/aiops_worker.py)
   • query Prometheus/Loki/Jaeger (bounded tenant/service/env/time)
   • detect: threshold + 3-sigma + EWMA + Isolation Forest
   • build normalized context BUNDLE (metrics/logs/deploys/ownership)
   • gửi Slack summary (dry-run hoặc SLACK_WEBHOOK_URL)
      ↓ POST /v1/triage  (bundle ĐÃ đầy đủ)
[Triage Engine API]  (AI team — app/main.py)
   • compute-first RCA + confidence gating + safety
   • GET /v1/reports, /v1/reports/{id} (report store)
   • optional Bedrock synthesis (AI_MODE=hybrid)
      ↓
triage report + ticket_payload + slack_payload + audit_id
```

**Mấu chốt:** `/v1/triage` **nhận bundle đã có sẵn metrics/logs/deploys/ownership**, engine KHÔNG tự đi lấy context. Component đi lấy context là **AIOps Worker** (cũng của AI team). POST với context rỗng → engine trả `INSUFFICIENT_CONTEXT`.

| Evidence | File | Dòng |
|---|---|---|
| Worker query observability + detect rồi mới gọi triage | `xBrain-capstone2/.../engine-skeleton/README.md` | 65 |
| Worker gửi Slack | README.md | 67, 71-75, 85 |
| Worker role (queries backends, normalizes, calls triage, publishes Slack) | README.md | 180 |
| `/v1/triage` nhận bundle (metrics/logs/recent_deploys/ownership) | `contracts/ai-api-contract.md` | 80-83 |
| "detector/context layer invokes API after data normalized" | ai-api-contract.md | 11 |
| Context rỗng → INSUFFICIENT_CONTEXT | ai-api-contract.md | 186 |
| AIOps owns interpretation; Platform ensures observable/queryable | `contracts/observability-data-contract.md` | 22 |

---

## 3. Ranh giới AI ↔ CDO (từ contract)

| Trách nhiệm | Owner | Evidence |
|---|---|---|
| AIOps Worker (query observability + detect + build bundle + Slack) | **AI** | README.md:65,67,180 |
| Triage Engine `/v1/triage` + RCA + report store | **AI** | ai-api-contract.md:45-51; README.md:25-27 |
| Container image (Dockerfile, app) | **AI** | engine-skeleton/Dockerfile |
| **Expose observability** (Prometheus/Loki/deploy/ownership, bounded, read-only) | **CDO** | observability-data-contract.md:22, 79, 93-97 |
| **Host engine** (compute, ALB, scale, secrets, network) | **CDO** | deployment-contract.md:9, 33-70 |
| CI/CD, GitOps, security baseline, observability deploy | **CDO** | deployment-contract.md:74-79 |
| Jira issue creation (consume ticket_payload) | **CDO** | handoff-1.txt:116-118 |
| SQS / integration transport | **CDO** | handoff-1.txt:16 |

---

## 4. Giao tiếp qua 4 Contract (freeze target 2026-06-25)

| Contract | File | Quy định chính | Ràng buộc CDO |
|---|---|---|---|
| Observability Data | `contracts/observability-data-contract.md` | CDO expose metrics/logs/deploy/ownership; scope tenant/service/env/time; freshness metrics<60s, logs<120s; query p95<2s; 0 leak | 🔴 deliverable lớn nhất |
| AI API | `contracts/ai-api-contract.md` | `POST /v1/triage` + `/healthz` + `/v1/reports`; bundle in → diagnosis out; status DIAGNOSED/INVESTIGATE/INSUFFICIENT_CONTEXT/UNSAFE_BLOCKED | build integration theo schema |
| Deployment | `contracts/deployment-contract.md` | ECS Fargate, internal ALB, min2/max6, /healthz:8080, us-east-1, SERVICE_AUTH_TOKEN | 🔴 spec hosting |
| Telemetry | `contracts/telemetry-contract.md` | định nghĩa field bundle | schema validation |

---

## 5. 🔴 ĐIỂM LỆCH giữa Diagram/Doc CDO và Contract/Code AI (CÓ EVIDENCE)

> Cột "CDO artifact" = diagram EKS (system + module) và `Triage-Hub/docs/reports/02_infra_design.md §8`.
> Cột "Ground truth" = contract/code nhóm AI, có file + dòng.

| # | Hạng mục | CDO artifact (hiện tại) | Ground truth (AI) | Evidence (file:dòng) | Mức |
|---|---|---|---|---|---|
| 1 | **Compute** | EKS + ArgoCD (diagram; `02_infra_design.md §8.5`) | **ECS Fargate** behind internal ALB | `deployment-contract.md:33`, `:91` | 🔴 |
| 2 | **Scaling max** | min2 / **max10** (`§8.6`, diagram KAN-205) | min2 / **max6** | `deployment-contract.md:45` | 🟡 |
| 3 | **SLA p99** | **< 500ms** (`§8.7`, diagram) | **< 2 seconds** | `ai-api-contract.md:207` | 🟡 |
| 4 | **Health path** | **/health** (diagram §8.5) | **/healthz** | `ai-api-contract.md:17,29`; `deployment-contract.md:21,121` | 🟡 |
| 5 | **Report endpoints** | chỉ `/v1/triage` | + `/v1/reports`, `/v1/reports/{id}`, `/raw` | `engine-skeleton/README.md:25-27` | 🟡 |
| 6 | **LLM** | **AgentCore** (`§8.5` IRSA `agentcore:InvokeAgent`; diagram 7a) | **Bedrock optional** (AI_MODE=hybrid, BEDROCK_MODEL_ID) — không có AgentCore trong contract/code | `deployment-contract.md:58-59`; ai-api-contract.md:51 | 🟡 |
| 7 | **Slack sender** | qua **CDO Lambda Dispatcher** (diagram §8.2) | **AIOps Worker (AI) tự gửi** SLACK_WEBHOOK_URL | `README.md:67,71-75` | 🔴 |
| 8 | **Context fetch** | engine query context (`§8.8`) | **Worker** query rồi truyền bundle vào `/v1/triage` | `README.md:65`; ai-api-contract.md:11,80-83 | 🟡 |
| 9 | **Auth /v1/triage** | IRSA (AWS only) | IRSA + **SERVICE_AUTH_TOKEN / SigV4** inter-service | `deployment-contract.md:61`; ai-api-contract.md (Authentication) | 🟡 |
| 10 | **AgentCore VPC endpoint** | có trong diagram §9 | contract chỉ cần CloudWatch/Secrets/Bedrock | `deployment-contract.md:71-72` | 🟡 |

### Giải thích 2 lệch đỏ

**#1 EKS vs Fargate** — `deployment-contract.md:33` ghi rõ `Target | ECS Fargate service behind an internal ALB`, `:45` ghi `min 2, max 6`. Diagram CDO dùng EKS + HPA min2/max10. Contract đang **Draft (freeze 25/06)** nên đây là lúc **push-back để đổi**, hoặc accept đây là angle riêng (cùng container chạy được). Phải raise tại co-design T5.

**#7 Slack** — `README.md:67` "the worker sends ... a concise summary", `:71-75` set `SLACK_WEBHOOK_URL` cho worker. Code AI **tự gửi Slack từ worker**. Diagram CDO route Slack qua Lambda Dispatcher. Trên kiến trúc **private-engine no-internet** của CDO, worker không ra `hooks.slack.com` được → phải chốt: Slack qua dispatcher+NAT (CDO) hay worker có NAT egress (AI).

### 5.1 Làm rõ quan trọng: Mentor KHÔNG bắt Fargate

Deviation #1 (EKS vs Fargate) **không phải vi phạm yêu cầu đề** — cần nói rõ kẻo hiểu nhầm:

- ❌ **Mentor KHÔNG bắt Fargate.** Đề cho mỗi CDO tự chọn angle. Evidence:
  - Capstone announcement: *"build infra hosting AI engine theo góc nhìn riêng (serverless, K8s, streaming, lakehouse...)"* → `docs/reference/` + `W11_W12_capstone_announcement.md`.
  - `TF1_TRIAGE_LEARNER.md`: *"Platform infra hosting AI engine theo angle riêng (serverless-first hoặc streaming-first hoặc khác)"*.
  - CDO template `02_infra_design.md`: component table ghi `Compute: <Lambda / Fargate / EKS>` (để chọn).
  - CDO template `03_security_design.md`: có sẵn mục "K8s RBAC (nếu CDO chọn EKS angle)", IRSA, NetworkPolicy, Pod Security → mentor lường trước angle EKS.
- ✅ **EKS là angle hợp lệ**, được mentor khuyến khích để differentiate (2-3 CDO compete trên execution quality).
- ⚠️ **"Fargate" chỉ là draft recommendation của nhóm AI** — `deployment-contract.md:33` (Status: Draft, freeze target 25/06) + `handoff-1.txt:100` ("ECS Fargate là hợp lý nhất" = gợi ý). Chưa ký → **push-back tại co-design T5** để giữ EKS, hoặc làm contract **compute-agnostic** ("Engine là Dockerized HTTP API port 8080 /healthz; CDO chọn runtime Fargate hoặc EKS"). Lý do chính đáng: contract dùng chung cho 2-3 CDO khác angle → không thể ép 1 compute.
- 📌 **Cần ADR** justify "sao chọn EKS thay Fargate" để defend panel (câu chắc chắn bị hỏi: *"AI recommend Fargate, sao em làm EKS?"*). Xem `08_adrs.md`.

→ Kết luận: giữ EKS hoàn toàn được, nhưng **phải reconcile deployment-contract trước khi ký T5** + có ADR. Không phải lỗi, là **deviation có chủ đích cần được chấp thuận chính thức**.

---

## 6. Mâu thuẫn nội bộ giữa Handoff và Contract

| Vấn đề | Handoff nói | Contract/Code nói | Evidence |
|---|---|---|---|
| Context fetch | "CDO gửi seed, **TF1 tự lấy context**" | bundle truyền vào `/v1/triage`; **Worker** lấy | handoff-1.txt:9-10 vs ai-api-contract.md:80-83, README.md:65 |
| LLM | **AgentCore** investigator | **Bedrock** optional synthesis | handoff-1.txt:12-13 vs deployment-contract.md:58-59 |
| Slack | "TF1 gửi Slack trực tiếp" | worker gửi (cùng ý) nhưng private-engine không cho | handoff-1.txt:104-105 vs README.md:67 |

→ Phải chốt 1 nguồn sự thật tại co-design.

---

## 7. Điểm thiếu / rủi ro / giả định

| Loại | Vấn đề | Mức |
|---|---|---|
| Thiếu | Ai host **AIOps Worker** (deployment AI riêng cần CDO host + network tới observability)? | 🔴 |
| Mâu thuẫn | AgentCore (handoff) vs Bedrock (contract/code) — chốt 1 | 🔴 |
| Giả định | "TF1 tự lấy context" vs "bundle truyền vào" — thực chất Worker lấy | 🔴 |
| Thiếu | SQS không có trong design AI; là transport CDO thêm → Worker chưa code consume SQS, cần shim | 🟡 |
| Rủi ro | Engine + Worker private nhưng cần ra Slack + observability → network path phải thiết kế | 🟡 |
| Giả định | Auth `/v1/triage`: SigV4 chưa sẵn → fallback SERVICE_AUTH_TOKEN | 🟡 |

---

## 8. Production readiness

| Khía cạnh | Mức | Ghi chú |
|---|---|---|
| Architecture | 🟡 | Còn lệch contract (compute, Slack owner, context fetch) |
| Security | 🟢 | IRSA scoped, ESO, audit immutable, Cosign, NetworkPolicy |
| Performance | 🟡 | p99<2s realistic; doc đang ghi 500ms |
| Scalability | 🟢 | HPA+CA (EKS) / target-tracking (Fargate); chỉnh max về 6 theo contract |
| Observability | 🟢 | đủ; nhưng phải **expose read-only cho AI** theo contract |
| Operability | 🟡 | EKS ops overhead cao hơn Fargate (deviation) |

---

## 9. Khuyến nghị (Principal Architect)

1. **Chốt compute tại co-design T5**: giữ EKS thì push-back đổi `deployment-contract.md:33,45` + viết ADR justify; hoặc theo Fargate cho đúng contract (ít rework), vẫn differentiate bằng GitOps/security/observability.
2. **Sửa diagram + `02_infra_design.md §8` cho khớp ground truth**: `/healthz`, p99<2s, max6, thêm `/v1/reports`, đổi AgentCore→Bedrock (hoặc chốt), vẽ **AIOps Worker** là component AI riêng (query observability + build bundle + call triage).
3. **Chốt 3 điểm với AI**: (a) ai host AIOps Worker; (b) Slack qua dispatcher+NAT trên private-engine; (c) AgentCore hay Bedrock.
4. **Collaboration model**:
   - AI owns: Worker + Engine container + RCA + payload shape.
   - CDO owns: observability backend (read-only bounded) + hosting + Jira creation + transport + egress (NAT cho SaaS).
   - Interface: 4 contracts, freeze 25/06, đổi qua change request.
5. **Target architecture**: giữ private engine + VPC endpoints + audit S3 Object Lock + buffer/DLQ **+ thêm AIOps Worker là deployment AI riêng + chốt compute + Slack qua dispatcher**.

---

## 10. Cho người mới — 8 câu trả lời

1. **Giải quyết gì:** tự động triage incident, giảm MTTA/MTTR, chống burnout on-call.
2. **Hoạt động sao:** seed → Worker lấy context + detect → `/v1/triage` RCA → report + Jira/Slack payload → người confirm.
3. **AI team làm:** Worker (context+detect) + Engine (RCA) + payload + Bedrock optional.
4. **CDO team làm:** expose observability + host engine/worker + CI/CD/GitOps/security + Jira creation + transport.
5. **2 team giao tiếp:** qua 4 contract; điểm chạm chính là `POST /v1/triage` (bundle in → diagnosis out) + observability read-only.
6. **Liên kết:** seed → Worker → triage API → report store → integration (Jira/Slack) → audit.
7. **Diagram đúng/sai:** đúng platform/security; **lệch compute (EKS vs Fargate), Slack owner, p99, /healthz, AgentCore vs Bedrock** (xem §5).
8. **Cần bổ sung trước khi build:** chốt compute, vẽ AIOps Worker, sửa SLA/health/endpoints, chốt Slack egress + LLM, xác định ai host Worker.

---

## Phụ lục — Evidence index (file:dòng)

**Repo AI `xBrain-capstone2/capstone/tf-1/ai/`:**
- `contracts/deployment-contract.md`: 12 (hosted once), 21 (/healthz, /v1/triage), 24 (port 8080), 33 (ECS Fargate), 34 (us-east-1), 35 (cluster), 37 (ECR repo), 45 (min2/max6), 46-47 (CPU70/req100), 58-59 (AI_MODE/BEDROCK_MODEL_ID), 61 (SERVICE_AUTH_TOKEN), 70 (internal ALB), 121 (health /healthz)
- `contracts/ai-api-contract.md`: 11 (detector/context invokes), 17/29 (/healthz), 45-51 (/v1/triage compute-first), 80-83 (bundle metrics/logs/deploys/ownership), 186 (empty→INSUFFICIENT_CONTEXT), 207 (p99<2s), 213 (no auto-remediate)
- `contracts/observability-data-contract.md`: 18 (AIOps ingestion/context service), 22 (Platform ensures / AIOps interprets), 79 (query scope), 93-94 (freshness 60s/120s), 96 (p95<2s), 97 (0 leak)
- `engine-skeleton/README.md`: 25-27 (/v1/reports), 65 (worker queries observability), 67/71-75/85 (worker sends Slack), 180 (aiops_worker role)

**Handoff:** `handoff-1.txt`: 9-10 (seed/context), 12-13 (AgentCore), 16 (transport CDO), 104-105 (Slack), 116-118 (Jira via CDO)

**CDO artifact cần sửa:** `Triage-Hub/docs/reports/02_infra_design.md §8.5-8.9` + 2 diagram (system + module).
