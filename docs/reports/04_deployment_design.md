# Deployment & CI/CD Design - Task force 1 · CDO

<!-- Doc owner: Nhóm CDO
     Status: Draft (W11 T4) -> Final (W11 T6 Pack #1) -> Working (W12 T4 Pack #2) -> Updated (W12 CI/CD alignment)
     Word target: 1200-2000 từ -->

## 1. IaC strategy (Owner: Kiên)

### 1.1 Tool choice

- **Công cụ IaC**: Nhóm dùng Terraform vì mỗi thay đổi hạ tầng đều có plan để review, có state rõ ràng và có thể dựng lại sandbox. Terraform đang quản lý VPC, EKS, ECR, Lambda, API Gateway, SQS, DynamoDB, Secrets Manager, observability và customer app mô phỏng.
- **State backend**: Terraform state lưu trên S3 và có lock. CI bootstrap state bucket khi cần, rồi chạy `terraform init` tại root sandbox. Các lệnh Terraform dùng `-lock-timeout=10m` để chờ lock thay vì fail ngay.
- **Cấu trúc module**: Hạ tầng tách thành module dùng chung và environment root. Root triển khai thật là `capstone/tf-1/devops/infra/environments/sandbox`. Staging/production vẫn là hướng mở rộng thiết kế; delivery hiện tập trung vào shared sandbox.

### 1.2 Module structure

```
infra/
├── modules/
│   ├── vpc/              # Platform and customer VPC networking
│   ├── security_group/   # Lambda, ALB, endpoints and EC2 boundaries
│   ├── ecr/              # Immutable AI engine image repository
│   ├── eks/              # EKS cluster, OIDC and access entries
│   ├── alb/              # Internal ALB / target group for AI engine
│   ├── lambda/           # alert/context/jira/slack/broadcast functions
│   ├── api_gateway/      # Public alert ingress and Lambda/SQS integrations
│   ├── sqs/              # Raw, buffer and dispatch queues with DLQs
│   ├── dynamodb/         # Triage state and audit records
│   ├── secrets_manager/  # Jira, Slack and service credentials
│   ├── eventbridge/      # Scheduled or broadcast notification hooks
│   ├── observability/    # CloudWatch dashboards, alarms and SNS
│   └── customer_app/     # Synthetic customer source for demo alerts
└── environments/
    └── sandbox/
```

### 1.3 State management

- Remote state dùng chung cho sandbox, nên mọi job CI đi qua cùng backend và cùng cơ chế lock.
- GitHub Actions dùng concurrency group `terraform-sandbox-state` cho apply/destroy để tránh hai thao tác Terraform chạy cùng lúc.
- Terraform plan được lưu thành artifact trước khi apply. Lambda payload ZIP sinh ra lúc plan được upload rồi tải lại ở apply job, giúp saved plan chạy được trên runner khác.
- Không chỉnh Terraform state thủ công, trừ cleanup có chủ ý với resource cũ và có log CI rõ ràng.

## 2. CI/CD pipeline (Owner: Kiên)

### 2.1 Pipeline stages

```
PR -> Validate -> Build/Package -> Scan -> Plan -> Review -> Merge -> Apply/Deploy -> Smoke
```

| Workflow | Trigger | Trách nhiệm chính | Gate |
|---|---|---|---|
| `ci-app.yml` | app PR/push, manual `deploy=true` | Lint/test app code, đóng gói Lambda ZIP, cập nhật Lambda code, chạy smoke check | Ruff/pytest/Bandit/Gitleaks và smoke AWS |
| `ci-infra.yml` | infra PR/push, schedule 07:17 ICT, manual apply | Terraform fmt/validate/scan, plan/apply sandbox, handoff ZIP sinh ra từ Terraform | Terraform plan/apply và Trivy/Checkov |
| `ci-ai-engine.yml` | AI engine PR/push/manual | Build AI image, scan bằng Trivy, push ECR SHA tag, ký Cosign, bump sandbox overlay | Unit test, image scan và signature |
| `platform-manifest-validate.yml` | platform PR/push/manual | Render Kustomize overlay và ArgoCD app, validate schema Kubernetes bằng kubeconform strict mode | Kustomize build và kubeconform validation |
| `terraform-destroy.yml` | schedule 00:00 ICT, manual confirm | Destroy sandbox chỉ khi guardrail cho phép | `ENABLE_AUTO_DESTROY`, `SKIP_AUTO_DESTROY`, `LEASE_UNTIL`, manual `destroy-sandbox` |

Thiết kế tách hạ tầng khỏi app code. App code đi qua `ci-app.yml` khi merge/push vào `develop` hoặc `main`. Infra đi qua `ci-infra.yml`, nhưng infra push/merge không tự dispatch App CI. App CI chỉ chạy sau infra khi scheduled sandbox hydration hoặc manual apply có `deploy_app_after_apply=true`.

### 2.2 Branch strategy

- `develop` = nhánh tích hợp hằng ngày. App và infra đều deploy sandbox từ nhánh này.
- `main` = nhánh demo-ready. Trong capstone này, `main` vẫn target sandbox vì chưa có account production riêng.
- `feature/*`, `fix/*`, `bugfix/*` = chỉ chạy PR validation, trừ khi workflow được approve thủ công.
- Mỗi Jira task chuyển Done cần có ít nhất một bằng chứng: commit SHA, PR URL, workflow URL, artifact hoặc screenshot.

## 3. GitOps (Owner: Kiên)

### 3.1 Tool

- **ArgoCD** quản lý desired Kubernetes state cho EKS platform. Terraform tạo AWS resource nền, lưu runtime value vào SSM khi cần và bootstrap ArgoCD/root app sau khi EKS sẵn sàng.
- **Cấu trúc repo** tách app code, Terraform và platform manifest để CI chạy check theo đúng path thay đổi.

```
capstone/tf-1/devops/
├── app/       # Lambda dispatcher và AI engine code
├── infra/     # Terraform module và sandbox root
└── platform/
    ├── argocd/
    ├── base/
    └── overlays/
        ├── sandbox/
        └── prod/
```

### 3.2 Sync waves

| Wave | Thành phần |
|---|---|
| -2 | Namespace, service account, RBAC |
| -1 | Operator/controller: External Secrets, Rollouts, KEDA, Gatekeeper, Sigstore policy controller |
| 0 | NetworkPolicy, ExternalSecret, ClusterSecretStore, ClusterImagePolicy |
| 1 | AI engine API/worker workload, service và ServiceMonitor |
| 2 | AnalysisTemplate, TargetGroupBinding, HPA và rollout analysis |

### 3.3 Drift detection

- ArgoCD phát hiện drift giữa Git và EKS cluster. Auto-sync kèm prune/self-heal có thể dùng cho sandbox manifest đã review, nhưng thay đổi platform phá hủy vẫn cần PR review.
- `platform-manifest-validate.yml` là guard trước ArgoCD. Workflow này render cùng Kustomize overlay mà ArgoCD sẽ consume và validate Kubernetes resource chuẩn bằng `kubeconform -strict`.
- Các CRD như Argo Rollouts, ExternalSecret, ServiceMonitor, TargetGroupBinding và Sigstore ClusterImagePolicy được ignore schema có chủ ý khi kubeconform không có schema mặc định.

## 4. Deployment strategy (Owner: Kiên)

### 4.1 Strategy

- **Lambda dispatchers**: App CI đóng gói và deploy bằng `aws lambda update-function-code`. Terraform sở hữu function, IAM, biến môi trường và trigger; App CI sở hữu update code.
- **AI engine**: API và worker dùng chung một ECR image nhưng khác command. Image dùng immutable SHA tag, được scan bằng Trivy và ký bằng Cosign.
- **Kubernetes runtime**: ArgoCD sync platform overlay. Argo Rollouts canary là chiến lược ưu tiên cho AI API: 10% -> 50% -> 100%, abort khi error rate, latency, health check hoặc restart count vượt ngưỡng.
- **Sandbox hydration**: scheduled infra apply lúc 07:17 ICT có thể dựng lại hạ tầng thiếu và dispatch App CI để deploy lại Lambda code hiện tại. Scheduled destroy lúc 00:00 ICT chỉ chạy khi guard variables cho phép.

### 4.2 Rollback method

- Lambda rollback: redeploy artifact cũ hoặc chạy lại App CI từ commit tốt đã biết.
- AI engine rollback: revert overlay tag về signed SHA trước đó để ArgoCD sync, hoặc abort Argo Rollouts canary để trả traffic về stable ReplicaSet.
- Infra rollback: revert Terraform commit và review plan mới. Chỉnh state chỉ là phương án bảo trì cuối cùng.
- Mục tiêu RTO cho app rollback ở sandbox là dưới 5 phút; infra rollback phụ thuộc thời gian thay thế AWS resource.

## 5. Environment separation (Owner: Kiên)

| Env | Mục đích | Account | Auto-deploy |
|---|---|---|---|
| Sandbox | Môi trường build, demo và integration dùng chung | Capstone AWS account | App deploy trên `develop/main`; infra apply qua push, schedule hoặc manual approval |
| Staging | Đường pre-demo validation tùy chọn | Cùng account, tách namespace/prefix nếu cần | Chỉ manual promotion |
| Prod | Ngoài phạm vi capstone | Chưa provision | Chỉ thiết kế |

Nhóm dùng một sandbox active để giảm overhead vận hành. Branch name, Terraform root và Kustomize overlay vẫn giữ đường mở rộng cho staging/prod.

## 6. Secrets in pipeline (Owner: Kiên)

- GitHub Actions dùng OIDC để assume AWS role. Workflow chỉ nên lưu role ARN trong secret/environment config, không lưu static AWS key.
- Jira, Slack và service-to-service secret nằm trong AWS Secrets Manager. EKS workload consume qua External Secrets khi phù hợp.
- Gitleaks kiểm tra secret bị commit trong app code. Bandit kiểm tra rủi ro Python. Trivy và Checkov kiểm tra image/IaC.
- Container image không được chứa runtime secret. Lambda và EKS workload nhận credential qua environment variable, Secrets Manager hoặc ExternalSecret.

## 7. Tenant onboarding deployment (Owner: Kiên)

```
1. Thêm tenant metadata: tenant_id, owner, Slack channel, Jira component và alert source.
2. Validate tenant config schema trước khi apply.
3. Provision hoặc map IAM, DynamoDB partition convention và notification routing theo tenant.
4. Gửi synthetic tenant alert qua API Gateway/SQS/Lambda/AI/Jira/Slack.
5. Gắn evidence vào Jira: commit SHA, workflow URL, smoke output và audit record ID.
```

Mục tiêu là onboard tenant demo dưới 30 phút. Self-service onboarding đầy đủ là future work; hiện tại ưu tiên luồng an toàn, lặp lại được.

## 8. Observability stack (Owner: Nhật)

| Component | Tool (Triển khai thực tế) |
|---|---|
| Metrics (AWS) | CloudWatch Standard Metrics & Container Insights (API GW, Lambda, SQS, DynamoDB, ALB, EC2, EKS) |
| Metrics (App) | 19 custom Prometheus metrics từ AI Engine (`prometheus_client`) — LLM cost, circuit breaker, idempotency, budget, agent iterations |
| Logs | CloudWatch Logs (`/aws/lambda/triage-hub-*`, EKS via Container Insights add-on); JSON structured log qua `aiops.engine` logger |
| Traces | AWS X-Ray (ServiceLens — API Gateway, Lambda, SQS) + OpenTelemetry OTLP (`aiops.engine` spans trong AI Engine) |
| Dashboards | CloudWatch Dashboard `triage-hub-dashboard-sandbox` (6 sections: Health Overview, Pipeline, Detailed Metrics, Logs Insights, Alarms, Cost & ServiceLens) |
| Alerts | CloudWatch Alarms (~22 alarms) + SNS `triage-hub-alerts-sandbox` (Email/SMS)|

## 9. Open questions (Owner: Kiên)

- [ ] Có nên đưa `platform-manifest-validate.yml` vào required status check trong GitHub ruleset không?
- [ ] Chính sách scheduled destroy cuối cùng là giữ `ENABLE_AUTO_DESTROY=false` mặc định hay bật nightly cleanup trong tuần demo?
- [ ] Staging có cần triển khai thật hay chỉ giữ ở mức thiết kế?
- [ ] Chốt tên Lambda và queue sau khi FIFO migration hoàn tất.

---

## 10. AI Engine Runtime Deployment — EKS angle (Owner: Thi)

<!-- Scope: deploy + scale AI Engine trên EKS qua GitOps. Bổ sung §3/§4, không ghi đè.
     Ground truth: ADR-003, 02_infra_design.md §8. -->

### 10.1 GitOps delivery

```
GitHub Actions CI -> ECR signed image -> Kustomize overlay -> ArgoCD app-of-apps -> EKS
                                                           |
                                                           -> Argo Rollouts canary
```

- `ci-ai-engine.yml` build, scan, push và ký image. Khi push, workflow cập nhật `newTag` trong sandbox overlay để ArgoCD rollout SHA mới.
- ArgoCD app-of-apps sync operator và app manifest từ `platform/argocd` và `platform/overlays`.
- Platform manifest validation chạy trước merge để bắt lỗi Kustomize patch hoặc field Kubernetes chuẩn sai.

### 10.2 Hai Deployment (namespace-per-tenant)

| Deployment | Vai trò | Probe | Image |
|---|---|---|---|
| `tf1-api` | `/v1/triage`, RCA, report store và synchronous API | `/healthz` | Cosign-signed SHA tag |
| `tf1-worker` | Consume SQS alert, chuẩn bị bundle, gọi API, emit triage result | `/healthz` | Cùng signed image với worker command |

Worker gọi `tf1-api` qua internal ALB. Public customer ingress nằm ngoài cluster, đi qua API Gateway và Lambda/SQS buffer.

### 10.3 Auto scaling

| Lớp | Cấu hình | Trigger |
|---|---|---|
| HPA | Scale theo CPU và request | CPU 70% và ALB/Prometheus request metrics |
| Cluster Autoscaler | Thêm/bớt EKS node | Pending pods |
| SQS Buffer | Hấp thụ alert bursty | Queue depth và DLQ visibility |

### 10.4 Rollback

- Primary: revert overlay tag hoặc abort Rollouts canary.
- Secondary: redeploy signed ECR SHA trước đó.
- Evidence: ArgoCD app history, workflow URL, image digest và smoke output.

### 10.5 IaC (Terraform module `eks/`)

Module `eks/` provision cluster, managed node group và OIDC provider cho IRSA. Kubernetes add-on và app resource được quản lý bằng GitOps khi có thể để giảm state drift.

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Thiết kế hạ tầng và kiến trúc AWS
- [`03_security_design.md`](03_security_design.md) - OIDC, IAM, secret scanning và runtime security
