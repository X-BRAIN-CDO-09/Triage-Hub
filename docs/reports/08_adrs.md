# Architecture Decision Records - CDO <M> · Task force <N>

<!-- Doc owner: <Nhóm CDO>
     Status: Ongoing log W11-W12
     Format: 1 ADR per major decision. Append-only - không xóa ADR cũ. -->

> **ADR là gì**: Architecture Decision Record. File log mỗi quyết định kiến trúc quan trọng + lý do tại sao chọn cái đó (chứ không phải mấy phương án khác). Mục đích: 6 tháng sau quay lại codebase vẫn nhớ "à hồi đó chọn X vì Y, không phải vì tôi thích".
>
> **Khi nào viết ADR**:
>
> - Decision có **trade-off thật** (chọn X có cost, chọn Y có benefit).
> - Decision **reversal cost cao** (vd đổi compute target = rebuild infra).
> - Decision có thể bị hỏi "sao chọn vậy?" trong Individual Defense buổi chấm.
>
> **KHÔNG cần ADR cho**: chuyện nhỏ không có trade-off (tên resource, naming convention, vv).
>
> **Khi 1 ADR cũ không còn áp dụng**: đánh dấu `Status: Superseded by ADR-NNN`, KHÔNG xóa ADR cũ. Append-only.

**Target**: ≥3 ADR cho Pack #1 (W11) · ≥5 ADR cho Pack #2 (W12).

**Ví dụ topic cần ADR (Nhóm CDO)**:

- Infra angle pick (serverless / K8s / streaming / lakehouse / managed observability)
- Compute target (Lambda vs ECS Fargate vs EKS)
- Data storage (DynamoDB vs RDS vs S3+Athena)
- CI/CD strategy (GitHub Actions vs CodePipeline, canary vs blue-green)
- Observability stack (Prometheus+Grafana vs CloudWatch native)
- Security baseline (IAM scope, secrets injection pattern, network isolation)
- Cost trade-off (Reserved Instance vs On-demand cho demo)

---

## ADR-001 - Kiến trúc Hybrid Compute (Serverless Ingestion + EKS Processing) (Owner: Tiến)

- **Status**: Accepted
- **Date**: 2026-06-23
- **Context**:
  - Hệ thống cần tiếp nhận các webhook cảnh báo từ nhiều tenant khách hàng SaaS B2B với tải lượng không đều và có thể xảy ra đột biến (alert spikes).
  - Sau khi tiếp nhận, hệ thống cần thực hiện thu thập dữ liệu log/metric và chạy AI Engine phân tích RCA phức tạp với thời gian xử lý kéo dài (lên tới hàng chục giây) và không bị ảnh hưởng bởi độ trễ khởi động lạnh (cold start).
- **Decision**:
  - Chọn mô hình **Kiến trúc Hybrid (Kết hợp)**:
    - Sử dụng **Serverless (API Gateway + AWS Lambda + SQS)** ở pha tiếp nhận đầu vào (Ingestion & Routing) để tự động scale và tối ưu chi phí idle.
    - Sử dụng **Amazon EKS (EKS Node Group)** ở pha xử lý AI chuyên sâu (AI Processing) nhằm chạy các pod AI App liên tục và cách ly tài nguyên tốt hơn.
- **Consequence**:
  - ✅ Cổng tiếp nhận (Ingestion DMZ) hoạt động độc lập, co giãn tức thì theo lưu lượng alert và bảo vệ cụm EKS hoàn toàn trong Subnet Private (không lộ diện public route).
  - ✅ SQS Queue đóng vai trò làm lớp đệm (buffer) giúp hấp thụ bão cảnh báo (alert storms) đột ngột, tránh gây quá tải tức thì cho cụm EKS.
  - ✅ EKS chạy các pod AI App liên tục giúp loại bỏ hoàn toàn trễ cold start và giới hạn thời gian chạy 15 phút của Lambda khi phân tích/thu thập logs lớn.
  - ✅ Hỗ trợ cách ly đa khách hàng (multi-tenant isolation) cứng ở mức hạ tầng (Kubernetes Namespaces, Network Policies, Resource Quotas).
  - ⚠️ Tăng độ phức tạp vận hành (Ops overhead) khi phải quản trị đồng thời cả Serverless (Lambda, Gateway, SQS) và cụm Kubernetes (EKS).
  - ⚠️ Phát sinh chi phí cố định tối thiểu cho cụm EKS (~$73/tháng + worker nodes) dù tải hệ thống thấp.
- **Alternatives considered**:
  - **Pure Serverless (Lambda-only)**: Bị từ chối vì gặp vấn đề cold start khi chạy logic LLM orchestration và có thể bị timeout khi xử lý logs dung lượng lớn.
  - **Pure Container (EKS + ALB / Ingress trực tiếp)**: Bị từ chối vì nếu route trực tiếp alert vào EKS sẽ bắt buộc phải expose ALB/Ingress ra internet, tăng bề mặt tấn công (attack surface) của cụm. Đồng thời thiếu hàng đợi SQS đệm có thể gây nghẽn/treo pod AI App khi gặp bão cảnh báo đột biến.

---

## ADR-002 - Sử dụng Database dùng chung (Shared Table DynamoDB) với Row-level Isolation (Owner: Tiến)

- **Status**: Accepted
- **Date**: 2026-06-23
- **Context**:
  - Hệ thống cần lưu trữ cấu hình tenant, metadata sự cố, audit log trạng thái với số lượng khách hàng ban đầu ≥ 50 tenants.
  - Cần một giải pháp lưu trữ có hiệu năng cao (sub-millisecond), chi phí tối thiểu ở quy mô nhỏ và đảm bảo tính cách ly dữ liệu giữa các tenant một cách chặt chẽ.
- **Decision**:
  - Sử dụng **Amazon DynamoDB** làm cơ sở dữ liệu chính dưới dạng **Shared Table (Pooled)**.
  - Phân tách logic dữ liệu bằng cách sử dụng `TenantID` làm Partition Key (PK).
- **Consequence**:
  - ✅ Chi phí lưu trữ cực rẻ nhờ mô hình Serverless hoàn toàn (Pay-per-use) và tận dụng Free Tier.
  - ✅ Thời gian phản hồi cực nhanh (sub-millisecond) và tự động scale theo tải.
  - ✅ Bảo mật dữ liệu được đảm bảo trực tiếp qua IAM Policy, hạn chế rủi ro lỗi logic từ mã nguồn ứng dụng gây rò rỉ chéo dữ liệu.
  - ⚠️ Khó thực hiện các truy vấn phức tạp hoặc báo cáo đa chiều do DynamoDB không hỗ trợ JOIN như SQL.
  - ⚠️ Sự phụ thuộc vào DynamoDB lookup có thể gây ảnh hưởng nếu gặp sự cố timeout (đã được giảm thiểu bằng cơ chế fallback tạo ticket unassigned).
- **Alternatives considered**:
  - **Amazon RDS PostgreSQL**: Bị từ chối vì tốn kém chi phí cố định cho instance và độ phức tạp khi quản lý connection pooling từ AWS Lambda.
  - **Siloed DynamoDB (Mỗi tenant 1 table)**: Bị từ chối do chi phí nhân lên gấp 50 lần mà không đem lại lợi ích bảo mật vượt trội so với Fine-Grained Access Control.

---

## ADR-003 - EKS (Kubernetes) cho AI Engine Runtime thay vì ECS Fargate (Owner: Thi)

- **Status**: Accepted
- **Date**: 2026-06-24
- **Scope**: Chỉ áp dụng cho **AI Engine Runtime module** — host `tf1-api` + `tf1-worker`. KHÔNG ghi đè compute choice của các service khác (do ADR-001 quyết).
- **Context**:
  - AI team handoff (`handoff-1.txt:88-100`) và `deployment-contract.md:24` ghi **reference compute = ECS Fargate** (hoặc Lambda nếu light load).
  - Tuy nhiên đề Phase 2 (`W11_W12_capstone_announcement.md`) **không bắt buộc** compute target — mỗi CDO chọn 1 _differentiation angle_ và defend. Recommend của AI team là gợi ý vận hành, **không phải ràng buộc kiến trúc**.
  - Engine cần: multi-tenant isolation mạnh (namespace-per-tenant), policy-as-code admission (Cosign verify, OPA), GitOps + canary, autoscaling 2 chiều (pod + node), secrets injection chuẩn (ESO/IRSA). Đây là các capability K8s-native.
- **Decision**: Chọn **Amazon EKS (managed node group)** làm runtime cho AI Engine, deploy qua **ArgoCD (app-of-apps) + Argo Rollouts canary**. Đây là angle khác biệt so với teammate (serverless/Fargate).
- **Consequence**:
  - ✅ Multi-tenant isolation end-to-end: Namespace + ResourceQuota + LimitRange + NetworkPolicy + RBAC + Pod Security `restricted` — sâu hơn Fargate task-level.
  - ✅ Supply-chain enforcement tại admission: Sigstore `policy-controller` chặn pod nếu image chưa Cosign-sign; Gatekeeper/OPA chặn root, hostNetwork, thiếu resource limit.
  - ✅ GitOps declarative + canary 10→50→100% auto-rollback (Argo Rollouts) — reproducible, audit-friendly.
  - ✅ Autoscaling 2 lớp: HPA (CPU 70% + custom ALB req/pod=100) + Cluster Autoscaler — tận dụng tốt cho alert bursty.
  - ✅ Tái dùng được stack đã học ở lab `aws-sercurity` + `w9/lab-final` (ArgoCD, ESO, Gatekeeper, Cosign, kube-prometheus-stack).
  - ⚠️ Ops overhead cao hơn Fargate: phải quản control plane add-ons, node group, K8s upgrade.
  - ⚠️ Fixed cost cao hơn (node luôn chạy min 2) so với Fargate scale-to-task — chấp nhận cho demo, bù bằng đúng angle.
  - ⚠️ Cần push-back để `deployment-contract.md` trở thành **compute-agnostic** (contract chỉ nên chốt I/O + port 8080 + `/health`, không chốt runtime). Bản frozen 25/06 (`Key principle`) **đã** xác nhận mỗi CDO tự host theo angle riêng, nên push-back này coi như được giải quyết.
- **Alternatives considered**:
  - **ECS Fargate** (AI team recommend): vận hành nhẹ, ít YAML, predictable. Rejected vì isolation chỉ ở task-level, không có admission policy-as-code, autoscaling chỉ 1 chiều, và **không tạo differentiation** so với teammate cũng dùng serverless.
  - **AWS Lambda**: rejected — engine có FastAPI long-running + background consumer + ML deps (numpy/scikit-learn), không hợp model 15-phút/stateless (`handoff-1.txt:88-93`).
- **Compatibility note**: Quyết định này **không đổi I/O contract**. Engine vẫn expose port 8080, health `/health` (`deployment-contract.md:122`), `POST /v1/triage` sync p99 < 500ms (`ai-api-contract.md:103`), nhận bundle input. EKS map các reference value của contract (min2/max10, CPU70/req100) sang HPA tương đương đúng tinh thần `Key principle`. Container image y hệt bản Fargate — chỉ khác lớp orchestration.

---

## ADR-004 - Quy trình tích hợp Jira-First (Jira trước, Slack sau) (Owner: Phong)

- **Status**: Accepted
- **Date**: 2026-06-24
- **Context**:
  - Khi có sự cố và kết quả phân tích AI hoàn thành, hệ thống cần vừa tạo ticket Jira vừa gửi thông báo kèm nút bấm trên Slack.
  - Nếu gửi Slack trước rồi tạo ticket Jira bất đồng bộ, có thể xảy ra tình trạng lỗi tạo ticket Jira sau đó dẫn tới mất dấu vết sự cố, hoặc kỹ sư tương tác với Slack alert khi ticket chưa được khởi tạo thành công trên Jira.
- **Decision**:
  - Áp dụng quy trình **Jira-First**: Hàm `jira-dispatcher` sẽ chịu trách nhiệm tạo ticket Jira trước tiên. Sau khi tạo thành công, `issue_key` sẽ được dùng làm correlation ID để tiếp tục kích hoạt sự kiện gửi thông báo Slack.
- **Consequence**:
  - ✅ Jira ticket luôn là Single Source of Truth cho mỗi incident. Mọi log, event và Slack payload đều được gắn kèm `issue_key` này để dễ dàng audit.
  - ✅ Ngăn ngừa mất mát dữ liệu (zero silent drops): bất kỳ sự cố kết nối Slack nào xảy ra thì ticket Jira vẫn tồn tại làm bằng chứng gốc.
  - ⚠️ Tăng thời gian trễ của việc hiển thị thông báo trên Slack thêm khoảng 2 giây do phải đợi API Jira phản hồi đồng bộ trước khi trigger Slack dispatcher.
  - ⚠️ Nếu Jira API bị sập hoàn toàn, hệ thống phải kích hoạt luồng fallback gửi tin nhắn raw alert lên Slack mà không có link Jira ticket.
- **Alternatives considered**:
  - **Slack-First Workflow**: Bị từ chối vì nếu Slack bị lỗi, sự cố sẽ bị bỏ qua và không có ticket nào được lưu vết. Đồng thời gây khó khăn cho việc quản lý trạng thái đồng bộ khi kỹ sư bấm nút phản hồi.
  - **Tạo đồng thời (Parallel creation)**: Bị từ chối vì khó map correlation ID (`issue_key`) vào tin nhắn Slack ngay lúc gửi, làm giảm tính liên kết dữ liệu.

---

## ADR-005 - Cơ chế Phân công Tương tác trên Slack - Human-in-the-loop (Owner: Hoàng)

- **Status**: Accepted
- **Date**: 2026-06-24
- **Context**:
  - AI Engine đề xuất người chịu trách nhiệm (suggested owner) dựa trên runbook và logs, nhưng độ chính xác thực tế chỉ đạt ~75%.
  - Nếu tự động gán thẳng (blind auto-assign) ticket Jira cho nhân sự đó mà không có sự kiểm tra lại, có nguy cơ cao gán sai người/sai team, dẫn tới ticket bị tồn đọng và tăng MTTA.
- **Decision**:
  - Triển khai cơ chế **Human-in-the-loop qua Slack**:
    - Tin nhắn Slack alert gửi đi chứa nút bấm tương tác **[Confirm & Assign]** đi kèm đề xuất của AI và nút **[Assign Me]** để nhận việc thủ công.
    - Việc gán ticket Jira chỉ thực sự diễn ra khi có kỹ sư on-call bấm nút xác nhận trên Slack.
- **Consequence**:
  - ✅ Giảm thiểu sai sót gán nhầm người/sai team xuống dưới 3% nhờ có con người kiểm duyệt trước khi phân công.
  - ✅ Tăng tính chủ động của đội trực ca, đảm bảo sự cố luôn được một người cụ thể tiếp nhận.
  - ⚠️ Yêu cầu mở cổng API Gateway public để nhận webhook callback từ Slack, đòi hỏi thiết lập cơ chế xác thực chữ ký (`X-Slack-Signature`) nghiêm ngặt.
  - ⚠️ Trải nghiệm của kỹ sư phụ thuộc vào thời hạn timeout 3s của Slack đối với các API callback (phải xử lý bất đồng bộ ở Lambda).
- **Alternatives considered**:
  - **Auto-assign hoàn toàn**: Bị từ chối do tỉ lệ gán sai cao (~25%), gây mất thời gian reassign thủ công trên giao diện Jira.
  - **Gửi Slack thô không có nút bấm**: Bị từ chối vì bắt buộc kỹ sư phải mở tab Jira, search ticket và gán tay, làm chậm đáng kể MTTA.

---

<!-- Append ADR mới ở dưới. Khi 1 ADR bị superseded, đánh dấu Status + link forward.

Suggested ADR areas (tham khảo, không bắt buộc đủ):
- Compute layer choice (Lambda vs Fargate vs EKS)
- Database choice + multi-tenant pattern (silo/pool/bridge)
- Event bus (EventBridge vs Kinesis vs MSK)
- IaC tool (Terraform vs CDK)
- GitOps tool (ArgoCD vs Flux)
- Observability stack (CloudWatch vs Grafana stack)
- Tenant isolation depth (compute level vs data level vs network level)
- Cost optimization trade-off (cold start vs always-on)
-->
