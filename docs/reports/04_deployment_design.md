# Deployment & CI/CD Design - Task force 1 · CDO

<!-- Doc owner: Nhóm CDO
     Status: Draft (W11 T4) -> Final (W11 T6 Pack #1) -> Working (W12 T4 Pack #2)
     Word target: 1200-2000 từ -->

## 1. IaC strategy (Owner: Kiên)

### 1.1 Tool choice

- **IaC tool**: Terraform. The repo already has reusable modules for VPC, security group, ECR, Lambda and the simulated customer app. Terraform is the safest choice for this capstone because it gives a reviewable plan before changing AWS resources, keeps infra changes in Git history, and lets each module map cleanly to the architecture diagram.
- **State backend**: S3 remote state with DynamoDB locking. The pipeline bootstraps the state bucket/table idempotently, then `terraform init` uses the configured backend in the sandbox root module. This avoids local state drift and prevents two people from applying at the same time.
- **Modular structure**: shared modules + environment-specific roots. The active root is `capstone/tf-1/devops/infra/environments/sandbox`; staging/prod folders remain placeholders until the demo platform is stable.

### 1.2 Module structure

```
infra/
├── modules/
│   ├── vpc/              # Platform VPC + simulated customer VPC
│   ├── security_group/   # Least-privilege network boundaries
│   ├── ecr/              # Immutable image repositories
│   ├── lambda/           # alert/context/jira/slack Lambda functions
│   ├── customer_app/     # Synthetic customer alert source
│   ├── api_gateway/      # Public alert ingress + Slack callback (planned)
│   ├── sqs/              # Buffer queues + DLQs (planned)
│   ├── s3/               # Audit artifacts (planned)
│   ├── secrets_manager/  # Jira/Slack/Bedrock secrets (planned)
│   └── observability/    # CloudWatch dashboards/alarms (planned)
├── environments/
│   ├── sandbox/
│   ├── staging/          # placeholder
│   └── prod/             # placeholder
└── README.md
```

### 1.3 State management

- Remote state per environment. `sandbox` stores state in S3 using `sandbox/terraform.tfstate`.
- State lock via DynamoDB table `triage-hub-tf-lock` or the `TF_LOCK_TABLE` repository variable.
- Plan-on-PR + apply-on-merge gate. PRs can show impact; apply is allowed only after merge or manual dispatch with `apply=true`.
- The state bucket must have versioning, encryption and public access block enabled before any app resources are deployed.

## 2. CI/CD pipeline (Owner: Kiên)

### 2.1 Pipeline stages

```
PR opened -> Build -> Test -> Scan -> Plan -> Review -> Merge -> Apply -> Smoke test
```

| Stage | Tool | What it does | Quality gate |
|---|---|---|---|
| Build | GitHub Actions + Docker | Build AI engine image and Lambda zip artifacts | Build success; artifact produced only when source exists |
| Test | Ruff + pytest | Lint, format check and unit tests for Python app code | No lint/test failure once implementation exists |
| Scan | Gitleaks + Bandit + Trivy + Checkov | Secret scan, Python security, image CVE and Terraform config scan | No committed secrets; no unfixed HIGH/CRITICAL image CVE |
| Plan | Terraform plan | Preview infra change for VPC, ECR, Lambda, queues and endpoints | Plan artifact generated and reviewable |
| Apply | Terraform apply | Deploy sandbox infrastructure after merge/manual approval | Apply success; outputs exported |
| Smoke | curl + AWS CLI | Health check API Gateway, SQS buffers/DLQs and runtime readiness | Required endpoints/resources are reachable |

The app workflow currently separates validation from deployment. On PR, it validates code only. On push to `develop`, it can build/push integration images. On push to `main` or manual `deploy=true`, it updates runtime components and runs smoke tests. This prevents feature branches from mutating AWS resources.

### 2.2 Branch strategy

- `main` = demo-ready branch. Runtime deploy is allowed from this branch only, except manual emergency runs.
- `develop` = integration branch. Infra can apply to sandbox and app images can be built for integration.
- `feature/*` = feature branches. Validation happens through PR checks before merge.
- PR required for merge to `main` + approval. Every closed Jira task must include a commit SHA, PR URL, workflow URL or screenshot evidence.

## 3. GitOps (Owner: Kiên)

### 3.1 Tool

- **ArgoCD** is the target GitOps controller for the EKS part of the platform. The current `kubectl set image` step is a bridge while manifests are being created; the final design should move image promotion into Git so ArgoCD owns cluster state.
- **Repo structure**: same repo, separated by folder. Application source remains under `app/`, Terraform under `infra/`, and desired Kubernetes/platform state should live under `platform/`.

```
capstone/tf-1/devops/
├── app/
├── infra/
└── platform/
    ├── argocd/
    ├── k8s/
    ├── policies/
    └── evidence/
```

### 3.2 Sync waves

| Wave | Components |
|---|---|
| -2 | Namespaces, service accounts, RBAC |
| -1 | External Secrets Operator, policy controllers, CRDs |
| 0 | ConfigMaps, ExternalSecrets, NetworkPolicies |
| 1 | AI engine Rollout, services, ServiceMonitor |
| 2 | AnalysisTemplate, dashboards, alert rules |

### 3.3 Drift detection

- ArgoCD detects drift between Git and the EKS cluster. Auto-sync can be enabled for non-destructive app manifests after the base platform is stable.
- Prune should stay disabled during capstone unless the change is reviewed, because accidental deletion of CRDs, secrets or network policy can break the demo.
- Daily drift report should be posted to the team Slack channel or attached as Jira evidence.
- Manual approval for destructive changes, policy changes and production-like namespace changes.

## 4. Deployment strategy (Owner: Kiên)

### 4.1 Strategy

- **Canary** (preferred): 10% -> 50% -> 100% over 15min for the AI engine once Argo Rollouts manifests exist.
- **Abort criteria**:
  - Error rate > 1%
  - P99 latency > AI API contract target
  - AI endpoint health check fails
  - Pod restart count increases during analysis
  - Bedrock/Jira/Slack fallback rate crosses agreed threshold
- **Auto-rollback** on abort

### 4.2 Rollback method

- **Primary**: Argo Rollouts abort returns traffic to the stable ReplicaSet. If GitOps is active, revert the manifest commit and let ArgoCD sync the previous image tag.
- **Secondary**: redeploy previous immutable ECR SHA tag for the AI engine.
- **Infra rollback**: revert the Terraform commit and apply the newly reviewed plan. We do not edit Terraform state manually.
- **Target RTO**: < 5 minutes for app rollback in the demo environment; infra rollback depends on resource type and must be tested before claiming a lower number.

## 5. Environment separation (Owner: Kiên)

| Env | Purpose | Account | Auto-deploy |
|---|---|---|---|
| Sandbox | Capstone build + integration | Shared capstone AWS account | Infra apply on `develop`/`main`; app deploy on `main` |
| Staging | Optional pre-demo validation | Same account, isolated namespace/prefix if time permits | Manual promotion only |
| Prod | Out of scope for capstone | Not used | Design-only |

The capstone uses a single active environment to avoid spending time on production ceremony before the demo path works. Naming, tags and Terraform roots still keep the path open for staging/prod later.

## 6. Secrets in pipeline (Owner: Kiên)

- CI accesses AWS through OIDC + IAM assume-role. Required GitHub secrets are role ARNs, not AWS access keys.
- Application secrets such as Jira API token, Slack webhook/signing secret, Bedrock config and webhook signing key must live in AWS Secrets Manager.
- PR secret scanning uses Gitleaks. Any leaked credential blocks merge and must be rotated before retry.
- Container images must not bake secrets. Runtime access should come from Lambda secret references or External Secrets Operator for EKS.

## 7. Tenant onboarding deployment (Owner: Kiên)

```
1. Add tenant metadata (`tenant_id`, service owners, Slack channel, Jira component) to a versioned config file or DynamoDB table.
2. Pipeline or onboarding script validates tenant config schema.
3. Terraform creates tenant-specific IAM boundaries, S3 audit prefix and DynamoDB partition conventions if required.
4. Smoke test sends a synthetic tenant-scoped alert and verifies no cross-tenant data appears in AI/Jira/Slack output.
5. Evidence is attached to Jira: commit SHA, smoke output and audit record ID.
```

Total time target: < 30 min for the capstone design. Full self-service onboarding can be design-only if core triage flow is not complete.

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

- [ ] Confirm final Lambda function names once Terraform Lambda composition is complete.
- [ ] Confirm whether AI engine runtime will use plain Deployment first or Argo Rollouts from the first EKS deploy.
- [ ] Confirm final queue names for `TRIAGE_QUEUE_NAMES` after SQS module is implemented.
- [ ] Confirm whether staging is required for the demo or remains design-only.

---

## 10. AI Engine Runtime Deployment — EKS angle (Owner: Thi)

<!-- Scope: deploy + scale AI Engine trên EKS qua GitOps. Bổ sung §3/§4, không ghi đè.
     Ground truth: ADR-003, 02_infra_design.md §8. -->

### 10.1 GitOps delivery

```
GitHub Actions CI ──► ECR (signed image) ──► ArgoCD (app-of-apps) ──► EKS
                                                   │
                                                   └─► Argo Rollouts (canary)
```

- **ArgoCD app-of-apps**: 1 root app sync các child app (manifests Kustomize/Helm).
- **Sync waves** cho engine: Wave 0 namespace + ESO secrets → Wave 1 NetworkPolicy/RBAC/Gatekeeper → Wave 2 `tf1-api` + `tf1-worker` Deployment → Wave 3 Ingress (Internal ALB) + HPA.
- **Argo Rollouts canary**: 10% → 50% → 100%, **auto-rollback on abort**. Abort gate: error rate > 1% hoặc **canary p99 > 800ms** (`deployment-contract.md:106`). Lưu ý phân biệt: 800ms là ngưỡng abort rollout, khác với SLA `/v1/triage` p99 < 500ms (`ai-api-contract.md:103`) — engine khoẻ thì 500ms < 800ms nên không tự rollback.

### 10.2 Hai Deployment (namespace-per-tenant)

| Deployment | Vai trò | Probe | Image |
|---|---|---|---|
| `tf1-api` (FastAPI) | `/v1/triage` sync + report store + compute-first RCA | readiness/liveness `/healthz` | Cosign-signed |
| `tf1-worker` (AIOps Worker) | consume seed từ SQS, detect, build bundle, gọi tf1-api nội bộ, emit payload | readiness/liveness `/healthz` | Cosign-signed |

Worker gọi tf1-api **đồng bộ qua Internal ALB** (private, TLS 1.2+, 443→8080).

### 10.3 Auto scaling

| Lớp | Cấu hình | Trigger |
|---|---|---|
| **HPA** | Policy 1: CPU 70% · Policy 2: ALB request/pod = 100 (Prometheus Adapter) | Min 2 / **Max 10 pods** (`deployment-contract.md:35`) |
| **Cluster Autoscaler** | thêm/bớt node khi pod pending | Min 2 / Max 10 nodes |
| **SQS Buffer** | đệm alert bursty trong lúc HPA kịp scale | queue depth |

### 10.4 Rollback

- Primary: ArgoCD rollback về Git SHA trước (declarative).
- Rollouts abort tự revert sang stable ReplicaSet, target RTO < 60s.

### 10.5 IaC (Terraform module `eks/`)

Module `capstone/tf-1/devops/infra/modules/eks/` provision: EKS cluster (managed node group, private), OIDC provider (IRSA), aws-load-balancer-controller add-on. ArgoCD/ESO/Gatekeeper cài qua GitOps bootstrap, không nằm trong Terraform state (declarative drift detection).

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Infra design này deploy theo strategy §1-§5 doc này
- [`03_security_design.md`](03_security_design.md) - Secret scanning + OIDC + IAM (this doc covers CI/CD security)
