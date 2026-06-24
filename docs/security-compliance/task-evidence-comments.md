# Nội dung Evidence để paste vào Jira

> Thay `<COMMIT_SHA>` và `<PR_URL>` bằng commit/PR thật sau khi push lên GitHub.

---

## KAN-218 - Multi-Tenant Isolation Controls

```text
Đã hoàn thành tài liệu thiết kế Multi-Tenant Isolation cho Triage Hub Security & Compliance.

Evidence:
- docs/security-compliance/tenant-isolation.md
- docs/03_security_design.md
- docs/08_adrs.md
- diagrams/security-compliance.drawio

Tóm tắt:
Thiết kế yêu cầu mọi alert phải có tenant_id, reject request thiếu tenant_id, lưu DynamoDB audit record theo tenant-scoped partition key, lưu S3 audit archive theo tenant prefix và đảm bảo AI request, Jira ticket, Slack notification, audit record đều có tenant context. Mục tiêu là đảm bảo không có cross-tenant access.

Commit: <COMMIT_SHA>
PR: <PR_URL>
```

---

## KAN-219 - Encryption for Data at Rest and In Transit

```text
Đã hoàn thành tài liệu thiết kế Encryption cho dữ liệu at rest và in transit.

Evidence:
- docs/security-compliance/encryption.md
- docs/03_security_design.md
- docs/08_adrs.md
- diagrams/security-compliance.drawio

Tóm tắt:
Thiết kế sử dụng KMS/SSE-KMS cho DynamoDB, S3, Secrets Manager và audit data. Tất cả luồng truyền dữ liệu bên ngoài sử dụng HTTPS/TLS, bao gồm API Gateway, AI endpoint, Jira API và Slack webhook. Jira token, Slack webhook và AI credential được lưu trong Secrets Manager hoặc SSM, không hardcode trong source code và không commit lên GitHub.

Commit: <COMMIT_SHA>
PR: <PR_URL>
```

---

## KAN-220 - End-to-End Audit Trail

```text
Đã hoàn thành tài liệu thiết kế End-to-End Audit Trail cho Triage Hub.

Evidence:
- docs/security-compliance/audit-trail.md
- docs/03_security_design.md
- docs/08_adrs.md
- diagrams/security-compliance.drawio

Tóm tắt:
Thiết kế audit trail ghi lại toàn bộ lifecycle của incident gồm ALERT_RECEIVED, TENANT_VALIDATED, CONTEXT_GATHERED, AI_DIAGNOSIS_REQUESTED, AI_DIAGNOSIS_COMPLETED, JIRA_TICKET_CREATED, SLACK_NOTIFICATION_SENT, ACKNOWLEDGED và FAILED_EVENT_RECORDED. Mỗi audit record có tenant_id, incident_id, trace_id, ai_decision_id, confidence_score, jira_ticket_id, slack_message_id và timestamp.

Commit: <COMMIT_SHA>
PR: <PR_URL>
```
