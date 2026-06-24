# 03 - Thiết kế Security & Compliance

## 1. Mục đích tài liệu

Tài liệu này mô tả thiết kế **Security & Compliance** cho nền tảng **TF1 - Triage Hub** của nhóm CDO. Nền tảng này nhận alert sự cố, gom ngữ cảnh như log/metric/recent deploy, gọi AI engine để chẩn đoán nguyên nhân, tạo Jira ticket, gửi thông báo Slack và lưu lại audit trail để truy vết.

Phần Security & Compliance tập trung vào 3 task Jira đang được giao:

1. **Tenant Isolation - Cô lập dữ liệu theo tenant**: alert, AI decision, Jira ticket, Slack activity và audit record của tenant này không được lẫn sang tenant khác.
2. **Encryption - Mã hóa dữ liệu**: dữ liệu nhạy cảm phải được mã hóa khi lưu trữ và khi truyền qua mạng.
3. **Audit Trail - Nhật ký truy vết đầu cuối**: mọi quyết định của AI và mọi hoạt động tích hợp với Jira/Slack phải có thể truy vết từ đầu đến cuối.

## 2. Phạm vi

### Trong phạm vi

- Triển khai AWS single-region tại `us-east-1`.
- Chỉ dùng dữ liệu synthetic hoặc sanitized, không dùng dữ liệu production thật.
- Jira là hệ thống ticket chính.
- Slack dùng để gửi thông báo và acknowledge.
- Xử lý alert có nhận diện tenant.
- Lưu audit record theo tenant.
- Mã hóa bằng AWS KMS, HTTPS/TLS và cơ chế mã hóa của từng AWS service.
- Tài liệu và evidence phục vụ review của mentor/PM.

### Ngoài phạm vi

- Không auto-remediation, AI không được tự sửa hệ thống.
- Không multi-region.
- Không dùng dữ liệu production thật.
- Không build custom UI/dashboard.
- Không build ServiceNow production integration.
- Không tích hợp PagerDuty.
- Không backfill ticket lịch sử.

## 3. Tổng quan kiến trúc security

```text
Tenant Alert
   ↓ HTTPS/TLS
API Gateway / Alert Ingestion
   ↓ validate tenant_id + validate schema
EventBridge
   ↓
Context Aggregator Lambda
   ↓
AI Diagnosis Endpoint
   ↓
Ticket + Notification Handler
   ├── Jira Ticket API qua HTTPS
   ├── Slack Webhook qua HTTPS
   └── DynamoDB Audit Trail + S3 Audit Archive

Các kiểm soát security áp dụng xuyên suốt:
- IAM least privilege
- KMS encryption
- Secrets Manager / SSM Parameter Store
- CloudWatch Logs retention
- X-Ray trace correlation
- Tenant isolation checks
```

## 4. Nguyên tắc security chính

| Nguyên tắc | Cách áp dụng trong Triage Hub |
|---|---|
| Least privilege | Mỗi Lambda/service role chỉ có quyền đúng với nhiệm vụ của nó. |
| Tenant isolation | Mọi request phải có `tenant_id`; dữ liệu được partition và query theo tenant. |
| Encrypt everything | DynamoDB, S3, Secrets Manager, CloudWatch Logs và integration secrets đều được mã hóa. |
| Không hardcode secret | Jira token, Slack webhook và AI credential phải nằm trong Secrets Manager hoặc SSM. |
| Auditability | Mỗi event quan trọng được ghi vào audit trail với `trace_id`, `tenant_id`, `incident_id`. |
| Human-in-the-loop | AI chỉ chẩn đoán và đề xuất remediation; AI không tự chạy lệnh sửa lỗi. |

## 5. Thiết kế Tenant Isolation

### 5.1 Field tenant bắt buộc

Mọi alert payload phải có các field tối thiểu:

```json
{
  "tenant_id": "tenant-a",
  "incident_id": "inc-001",
  "service_name": "payment-service",
  "severity": "high",
  "timestamp": "2026-06-24T10:00:00Z"
}
```

Nếu thiếu `tenant_id`, hệ thống phải reject request và ghi audit event loại `TENANT_VALIDATION_FAILED`.

### 5.2 Quy tắc partition dữ liệu

DynamoDB audit table nên dùng partition key theo tenant:

```text
PK = TENANT#<tenant_id>
SK = INCIDENT#<incident_id>#EVENT#<timestamp>
```

Ví dụ:

```text
PK = TENANT#tenant-a
SK = INCIDENT#inc-001#EVENT#2026-06-24T10:00:00Z
```

Quy tắc này giúp tất cả query audit, incident history và AI decision đều bị giới hạn trong tenant hiện tại.

### 5.3 Cô lập S3 audit archive

S3 prefix phải có tenant:

```text
s3://triage-hub-audit/tenant_id=tenant-a/year=2026/month=06/day=24/incident_id=inc-001.json
```

Không được ghi chung tất cả audit record vào một prefix không có tenant.

### 5.4 Kiểm soát ở tầng xử lý

- API Gateway/Lambda validate `tenant_id` ngay đầu vào.
- Context Aggregator chỉ query log/metric/deploy metadata thuộc cùng `tenant_id`.
- AI request phải chứa `tenant_id`, `incident_id`, `trace_id`.
- Jira ticket phải có field `tenant_id` hoặc label tương ứng.
- Slack message phải chứa tenant/service context cần thiết, không leak thông tin tenant khác.
- Audit Writer luôn ghi `tenant_id` vào record.

### 5.5 Test case cần chứng minh

| Test case | Kết quả mong muốn |
|---|---|
| Alert thiếu `tenant_id` | Request bị reject. |
| Tenant A gửi alert | Chỉ lấy context của Tenant A. |
| Tenant B query incident của Tenant A | Không truy cập được. |
| Audit record của Tenant A | Có `tenant_id=tenant-a`. |
| Jira/Slack output | Không chứa dữ liệu của tenant khác. |

## 6. Thiết kế Encryption

### 6.1 Encryption at rest - mã hóa khi lưu trữ

| Thành phần | Cơ chế mã hóa |
|---|---|
| DynamoDB Audit Table | AWS KMS encryption. |
| S3 Audit Archive | SSE-KMS. |
| Secrets Manager | KMS-managed encryption. |
| SSM Parameter Store | SecureString + KMS nếu dùng SSM. |
| CloudWatch Logs | Log group encryption + retention policy. |
| ECR Image Repository | Image scanning + encryption mặc định/KMS nếu cấu hình. |

### 6.2 Encryption in transit - mã hóa khi truyền

| Luồng dữ liệu | Yêu cầu |
|---|---|
| Alert Source → API Gateway | HTTPS/TLS. |
| Lambda → AI Engine Endpoint | HTTPS/TLS hoặc private endpoint có TLS. |
| Lambda → Jira API | HTTPS/TLS. |
| Lambda → Slack Webhook | HTTPS/TLS. |
| CI/CD → AWS | HTTPS/TLS + IAM authentication. |

### 6.3 Secrets management

Không được commit các thông tin sau lên GitHub:

```text
JIRA_API_TOKEN
SLACK_WEBHOOK_URL
AI_SERVICE_API_KEY
DATABASE_PASSWORD
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

Các secret phải được lưu ở:

```text
AWS Secrets Manager
hoặc
AWS Systems Manager Parameter Store - SecureString
```

Lambda chỉ được đọc đúng secret mà nó cần thông qua IAM policy least privilege.

## 7. Thiết kế Audit Trail

### 7.1 Mục tiêu audit

Audit trail phải trả lời được các câu hỏi:

- Alert nào đã xảy ra?
- Thuộc tenant nào?
- Incident ID là gì?
- Trace ID là gì?
- AI đã được gọi lúc nào?
- AI trả diagnosis gì?
- Confidence score bao nhiêu?
- Jira ticket nào được tạo?
- Slack message nào được gửi?
- Ai acknowledge và acknowledge lúc nào?

### 7.2 Event types cần lưu

```text
ALERT_RECEIVED
TENANT_VALIDATED
CONTEXT_GATHERED
AI_DIAGNOSIS_REQUESTED
AI_DIAGNOSIS_COMPLETED
JIRA_TICKET_CREATED
SLACK_NOTIFICATION_SENT
ACKNOWLEDGED
FAILED_EVENT_RECORDED
```

### 7.3 Schema audit record đề xuất

```json
{
  "tenant_id": "tenant-a",
  "incident_id": "inc-001",
  "trace_id": "trace-abc-123",
  "event_type": "AI_DIAGNOSIS_COMPLETED",
  "timestamp": "2026-06-24T10:00:00Z",
  "service_name": "payment-service",
  "severity": "high",
  "ai_decision_id": "decision-001",
  "confidence_score": 0.86,
  "jira_ticket_id": "KAN-999",
  "slack_message_id": "msg-123",
  "status": "SUCCESS"
}
```

### 7.4 Lưu trữ audit

- **DynamoDB**: dùng cho query nhanh theo tenant/incident.
- **S3**: dùng làm audit archive dài hạn.
- **CloudWatch Logs**: dùng debug runtime.
- **X-Ray**: dùng trace lifecycle của request.

## 8. IAM và least privilege

### 8.1 Lambda Alert Processor Role

Chỉ nên có quyền:

- ghi log vào CloudWatch Logs;
- put event vào EventBridge nếu cần;
- đọc secret cần thiết;
- gọi AI endpoint nếu dùng IAM/private integration;
- ghi audit record vào DynamoDB;
- ghi archive vào S3 prefix được phép.

### 8.2 Audit Writer Role

Chỉ nên có quyền:

- `dynamodb:PutItem` vào audit table;
- `dynamodb:Query` theo tenant/incident nếu cần;
- `s3:PutObject` vào audit bucket/prefix;
- không có quyền xóa audit record production/demo nếu không cần.

### 8.3 Secrets Access Role

Mỗi integration chỉ được đọc secret của chính nó:

```text
Jira Connector → chỉ đọc Jira API token
Slack Connector → chỉ đọc Slack webhook
AI Connector → chỉ đọc AI service credential
```

## 9. Compliance controls

| Yêu cầu compliance | Cách chứng minh |
|---|---|
| Không leak cross-tenant | Test tenant A/B và audit query evidence. |
| Audit coverage 100% | Mỗi bước chính có audit event. |
| Secret không hardcode | Repo không chứa token; dùng Secrets Manager/SSM. |
| Encryption at rest | KMS/SSE-KMS cho DynamoDB/S3/Secrets. |
| Encryption in transit | HTTPS/TLS cho API Gateway, AI, Jira, Slack. |
| Traceability | Mỗi event có `trace_id`, `tenant_id`, `incident_id`. |

## 10. Evidence cần nộp

- `docs/03_security_design.md` - tài liệu tổng hợp Security & Compliance.
- `docs/security-compliance/tenant-isolation.md` - chi tiết tenant isolation.
- `docs/security-compliance/encryption.md` - chi tiết encryption.
- `docs/security-compliance/audit-trail.md` - chi tiết audit trail.
- `docs/08_adrs.md` - các quyết định kiến trúc security.
- `diagrams/security-compliance.drawio` - sơ đồ security & compliance.
- Commit SHA và Pull Request URL được dán vào Jira KAN-218, KAN-219, KAN-220.

## 11. Rủi ro và cách giảm thiểu

| Rủi ro | Cách giảm thiểu |
|---|---|
| Thiếu `tenant_id` trong payload | Reject request ngay đầu vào và log audit event. |
| Query nhầm dữ liệu tenant khác | Dùng partition key theo tenant và kiểm tra tenant trước khi query. |
| Secret bị commit lên GitHub | Dùng `.gitignore`, secret scanning và Secrets Manager/SSM. |
| AI endpoint/Jira/Slack lỗi | Retry có giới hạn, DLQ và audit event `FAILED_EVENT_RECORDED`. |
| Không đủ audit evidence | Bắt buộc ghi audit tại từng bước quan trọng. |
