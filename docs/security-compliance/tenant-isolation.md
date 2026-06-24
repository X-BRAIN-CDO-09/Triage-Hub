# Thiết kế Multi-Tenant Isolation

## 1. Mục tiêu

Tài liệu này mô tả cách nền tảng **Triage Hub** đảm bảo dữ liệu giữa các tenant được cô lập. Mục tiêu chính là: **tenant này không được truy cập, nhìn thấy hoặc bị lẫn dữ liệu của tenant khác**.

Task liên quan:

```text
KAN-218 - Implement Multi-Tenant Isolation Controls
```

## 2. Lý do cần tenant isolation

Triage Hub xử lý alert, log, metric, AI decision, Jira ticket, Slack notification và audit record. Những dữ liệu này có thể chứa thông tin nhạy cảm về service, incident và khách hàng. Nếu dữ liệu tenant A bị lẫn sang tenant B thì hệ thống vi phạm yêu cầu bảo mật và compliance.

Ví dụ:

```text
Tenant A = công ty A
Tenant B = công ty B
```

Khi alert của Tenant A xảy ra, hệ thống chỉ được lấy log/metric/ticket/audit của Tenant A. Tenant B không được thấy dữ liệu này.

## 3. Nguyên tắc thiết kế

| Nguyên tắc | Cách áp dụng |
|---|---|
| Tenant bắt buộc | Mọi alert/request phải có `tenant_id`. |
| Cô lập từ đầu vào | Validate `tenant_id` ngay tại API Gateway/Lambda. |
| Cô lập khi query | Mọi query phải filter/partition theo tenant. |
| Cô lập khi lưu | DynamoDB/S3 lưu dữ liệu theo tenant. |
| Cô lập khi tích hợp | AI/Jira/Slack payload đều có `tenant_id`. |
| Có audit | Mọi bước tenant validation đều được ghi audit. |

## 4. Payload bắt buộc

Alert payload tối thiểu:

```json
{
  "tenant_id": "tenant-a",
  "incident_id": "inc-001",
  "service_name": "payment-service",
  "alert_type": "latency_degradation",
  "severity": "high",
  "timestamp": "2026-06-24T10:00:00Z"
}
```

Nếu thiếu `tenant_id`, hệ thống trả lỗi:

```json
{
  "error": "TENANT_ID_REQUIRED",
  "message": "tenant_id is required for all alert events"
}
```

## 5. Luồng xử lý tenant isolation

```text
Alert Source
   ↓
API Gateway
   ↓
Validate schema + tenant_id
   ↓
Nếu hợp lệ → EventBridge
Nếu không hợp lệ → Reject + ghi audit event
   ↓
Context Aggregator chỉ lấy dữ liệu cùng tenant
   ↓
AI request có tenant_id
   ↓
Jira ticket có tenant_id
   ↓
Slack message có tenant context
   ↓
Audit record lưu theo tenant_id
```

## 6. Thiết kế DynamoDB key

Audit table nên dùng key theo tenant:

```text
PK = TENANT#<tenant_id>
SK = INCIDENT#<incident_id>#EVENT#<timestamp>
```

Ví dụ:

```text
PK = TENANT#tenant-a
SK = INCIDENT#inc-001#EVENT#2026-06-24T10:00:00Z
```

Query đúng:

```text
Query PK = TENANT#tenant-a
```

Không được query kiểu:

```text
Scan toàn bảng không filter tenant
```

## 7. Thiết kế S3 prefix

Audit archive trong S3 nên chia theo tenant:

```text
s3://triage-hub-audit/tenant_id=tenant-a/year=2026/month=06/day=24/incident_id=inc-001.json
```

Lợi ích:

- dễ truy vết theo tenant;
- dễ áp dụng lifecycle policy;
- giảm nguy cơ đọc nhầm dữ liệu tenant khác;
- dễ export evidence khi mentor yêu cầu.

## 8. Quy tắc với AI Engine

Khi gọi AI endpoint, request phải có:

```json
{
  "tenant_id": "tenant-a",
  "incident_id": "inc-001",
  "trace_id": "trace-abc-123",
  "service_name": "payment-service",
  "context": {
    "logs": [],
    "metrics": {},
    "recent_deploys": []
  }
}
```

AI response cũng nên trả lại `tenant_id`, `incident_id`, `trace_id` để CDO đối chiếu trước khi tạo Jira/Slack/audit.

## 9. Quy tắc với Jira và Slack

### Jira ticket

Jira ticket phải có ít nhất:

```text
tenant_id
incident_id
service_name
severity
confidence_score
ai_decision_id
audit_trace_id
```

### Slack notification

Slack message phải route theo team owner mapping và không chứa dữ liệu tenant khác. Nếu chưa có mapping thật, demo có thể dùng mapping synthetic:

```json
{
  "payment-service": "#team-payment-alerts",
  "auth-service": "#team-auth-alerts"
}
```

## 10. Test cases

| ID | Test case | Kết quả mong muốn |
|---|---|---|
| TI-01 | Gửi alert thiếu `tenant_id` | Bị reject. |
| TI-02 | Gửi alert cho `tenant-a` | Chỉ tạo audit/Jira/Slack cho tenant-a. |
| TI-03 | Query audit tenant-a | Không trả record của tenant-b. |
| TI-04 | AI response thiếu hoặc sai tenant_id | Không tạo Jira/Slack, ghi lỗi audit. |
| TI-05 | Slack/Jira payload | Có tenant context, không leak tenant khác. |

## 11. Acceptance Criteria

```text
No Cross-Tenant Access
```

Điều kiện hoàn thành:

- Alert bắt buộc có `tenant_id`.
- DynamoDB/S3 partition theo tenant.
- AI/Jira/Slack/audit đều có tenant context.
- Có test case chứng minh tenant A không truy cập dữ liệu tenant B.
- Có diagram và documentation trong repo.
