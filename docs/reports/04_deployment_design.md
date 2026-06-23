# Deployment & CI/CD Design - Task force <N> · CDO <M>

<!-- Doc owner: <Nhóm CDO>
     Status: Draft (W11 T4) → Final (W11 T6 Pack #1) → Working (W12 T4 Pack #2)
     Word target: 1200-2000 từ -->

## 1. IaC strategy (Owner: Kiên)

### 1.1 Tool choice

- **IaC tool**: <Terraform / CDK / CloudFormation> - justify
- **State backend**: <S3 + DynamoDB lock / Terraform Cloud>
- **Modular structure**: shared modules + environment-specific roots

### 1.2 Module structure

```
infra/
├── modules/
│   ├── networking/        # VPC, subnets, SG
│   ├── compute/           # ECS/Lambda/EKS
│   ├── data/              # RDS/DynamoDB
│   ├── tenant-provision/  # per-tenant resources
│   └── observability/
├── environments/
│   ├── sandbox/
│   ├── staging/
│   └── prod/
└── README.md
```

### 1.3 State management

- Remote state per environment
- State lock via DynamoDB
- Plan-on-PR + apply-on-merge gate

## 2. CI/CD pipeline (Owner: Kiên)

### 2.1 Pipeline stages

```
PR opened ──► Build ──► Test ──► Scan ──► Plan ──► Review ──► Merge ──► Apply ──► Smoke test
```

| Stage | Tool | What it does | Quality gate |
|---|---|---|---|
| Build | <GitHub Actions> | Compile + container build | Build success |
| Test | <pytest / go test> | Unit + integration | Coverage ≥ X% |
| Scan | <Trivy + Snyk> | Image vuln + dependency CVE | No CRITICAL |
| Plan | Terraform plan | Preview infra change | Plan review |
| Apply | Terraform apply | Deploy infra | Apply success |
| Smoke | <custom script> | Health check post-deploy | All endpoints 200 |

### 2.2 Branch strategy

- `main` = production-ready
- `develop` = integration
- `feature/*` = feature branches
- PR required for merge to `main` + approval

## 3. GitOps (Owner: Kiên)

### 3.1 Tool

- **ArgoCD** (preferred) or Flux
- **Repo structure**: separate "app" repo and "config" repo

### 3.2 Sync waves

| Wave | Components |
|---|---|
| 0 | Namespace, secrets, configmaps |
| 1 | CRDs (if any) |
| 2 | Database, cache |
| 3 | Backend services |
| 4 | Frontend, ingress |

### 3.3 Drift detection

- ArgoCD auto-sync with prune disabled
- Daily drift report → Slack channel
- Manual approval cho destructive change

## 4. Deployment strategy (Owner: Kiên)

### 4.1 Strategy

- **Canary** (preferred): 10% → 50% → 100% over 15min
- **Abort criteria**:
  - Error rate > 1%
  - P99 latency > 800ms
  - Burn rate fast alert triggered
- **Auto-rollback** on abort

### 4.2 Rollback method

- **Primary**: ArgoCD rollback to previous Git SHA
- **Secondary**: Terraform state rollback (if infra change)
- **Target RTO**: < 60s

## 5. Environment separation (Owner: Kiên)

| Env | Purpose | Account | Auto-deploy |
|---|---|---|---|
| Sandbox | Dev experimentation | <account-1> | On PR |
| Staging | Pre-prod integration | <account-2> | On merge to `develop` |
| Prod | Real tenant traffic | <account-3> | On merge to `main` + manual approval |

## 6. Secrets in pipeline (Owner: Kiên)

- CI accesses secrets via OIDC + IAM assume-role (no static keys in CI)
- Secret scanning trên PR (Gitleaks / TruffleHog)
- Block merge if secret detected

## 7. Tenant onboarding deployment (Owner: Kiên)

```
1. POST /tenants → trigger Step Function
2. SF invokes Terraform module `tenant-provision`
3. Module creates: IAM role + DB schema + namespace + initial secrets
4. Smoke test runs
5. Callback to API: tenant ready
```

Total time target: < 30 min.

## 8. Observability stack (Owner: Nhật)

| Component | Tool |
|---|---|
| Metrics | CloudWatch / Prometheus |
| Logs | CloudWatch Logs / Loki |
| Traces | OpenTelemetry → X-Ray / Jaeger |
| Dashboards | CloudWatch / Grafana |
| Alerts | CloudWatch Alarms / Alertmanager |

## 9. Open questions (Owner: Kiên)

- [ ] Q1: ...

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Infra design này deploy theo strategy §1-§5 doc này
- [`03_security_design.md`](03_security_design.md) - Secret scanning + OIDC + IAM (this doc covers CI/CD security)
