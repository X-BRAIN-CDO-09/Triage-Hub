# Architecture Decision Records - CDO <M> · Task force <N>

<!-- Doc owner: <Nhóm CDO>
     Status: Ongoing log W11-W12
     Format: 1 ADR per major decision. Append-only - không xóa ADR cũ. -->

> **ADR là gì**: Architecture Decision Record. File log mỗi quyết định kiến trúc quan trọng + lý do tại sao chọn cái đó (chứ không phải mấy phương án khác). Mục đích: 6 tháng sau quay lại codebase vẫn nhớ "à hồi đó chọn X vì Y, không phải vì tôi thích".
>
> **Khi nào viết ADR**:
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

## ADR-001 - <Short title, e.g., "Lambda over Fargate for compute layer"> (Owner: Tiến)

- **Status**: Accepted | Proposed | Superseded by ADR-NNN | Rejected
- **Date**: 2026-MM-DD
- **Context**: <1-3 câu tại sao có decision này. What forced it?>
- **Decision**: <chốt cụ thể gì>
- **Consequence**:
  - ✅ Pro 1
  - ✅ Pro 2
  - ⚠️ Trade-off 1
  - ⚠️ Trade-off 2
- **Alternatives considered**:
  - Option A: ... (rejected because ...)
  - Option B: ... (rejected because ...)

---

## ADR-002 - <Short title>

- **Status**: ...
- **Date**: ...
- **Context**: ...
- **Decision**: ...
- **Consequence**: ...
- **Alternatives considered**: ...

---

## ADR-003 - EKS (Kubernetes) cho AI Engine Runtime thay vì ECS Fargate (Owner: Thi)

- **Status**: Accepted
- **Date**: 2026-06-24
- **Scope**: Chỉ áp dụng cho **AI Engine Runtime module** — host `tf1-api` + `tf1-worker`. KHÔNG ghi đè compute choice của các service khác (do ADR-001 quyết).
- **Context**:
  - AI team handoff (`handoff-1.txt:88-100`) và `deployment-contract.md:24` ghi **reference compute = ECS Fargate** (hoặc Lambda nếu light load).
  - Tuy nhiên đề Phase 2 (`W11_W12_capstone_announcement.md`) **không bắt buộc** compute target — mỗi CDO chọn 1 *differentiation angle* và defend. Recommend của AI team là gợi ý vận hành, **không phải ràng buộc kiến trúc**.
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
