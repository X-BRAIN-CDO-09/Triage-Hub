# Thiết kế End-to-End Audit Trail

## 1. Mục tiêu

Tài liệu này mô tả thiết kế audit trail đầu cuối cho **Triage Hub**. Mục tiêu là mọi bước từ lúc alert xuất hiện đến khi Jira ticket/Slack notification được tạo đều có thể truy vết.

Task liên quan:

```text
KAN-220 - Implement End-to-End Audit Trail
```

## 2. Vì sao cần audit trail

Triage Hub dùng AI để chẩn đoán incident và đề xuất remediation. Vì vậy hệ thống cần trả lời được:

- AI đã dựa trên dữ liệu nào để đưa ra diagnosis?
- AI confidence score bao nhiêu?
- Jira ticket nào được tạo từ AI decision đó?
- Slack message nào đã được gửi?
- Ai acknowledge incident?
- Có lỗi nào xảy ra trong pipeline không?

Audit trail giúp team chứng minh tính minh bạch, traceability và compliance.

## 3. Luồng audit đầu cuối

```text
ALERT_RECEIVED
   ↓
TENANT_VALIDATED
   ↓
CONTEXT_GATHERED
   ↓
AI_DIAGNOSIS_REQUESTED
   ↓
AI_DIAGNOSIS_COMPLETED
   ↓
JIRA_TICKET_CREATED
   ↓
SLACK_NOTIFICATION_SENT
   ↓
ACKNOWLEDGED
```

Nếu có lỗi:

```text
FAILED_EVENT_RECORDED
```

## 4. Audit event types

| Event type | Ý nghĩa |
|---|---|
| ALERT_RECEIVED | Hệ thống nhận alert đầu vào. |
| TENANT_VALIDATED | Đã kiểm tra tenant_id hợp lệ. |
| CONTEXT_GATHERED | Đã gom log/metric/deploy metadata. |
| AI_DIAGNOSIS_REQUESTED | Đã gửi request sang AI endpoint. |
| AI_DIAGNOSIS_COMPLETED | AI đã trả diagnosis/confidence/action. |
| JIRA_TICKET_CREATED | Đã tạo Jira ticket. |
| SLACK_NOTIFICATION_SENT | Đã gửi Slack notification. |
| ACKNOWLEDGED | Engineer đã acknowledge incident. |
| FAILED_EVENT_RECORDED | Một bước trong pipeline bị lỗi. |

## 5. Schema audit record đề xuất

```json
{
  "tenant_id": "tenant-a",
  "incident_id": "inc-001",
  "trace_id": "trace-abc-123",
  "event_type": "AI_DIAGNOSIS_COMPLETED",
  "timestamp": "2026-06-24T10:00:00Z",
  "service_name": "payment-service",
  "alert_type": "latency_degradation",
  "severity": "high",
  "ai_decision_id": "decision-001",
  "confidence_score": 0.86,
  "jira_ticket_id": "KAN-999",
  "slack_message_id": "msg-123",
  "acknowledged_by": null,
  "status": "SUCCESS",
  "error_message": null
}
```

## 6. DynamoDB audit table design

Key design:

```text
PK = TENANT#<tenant_id>
SK = INCIDENT#<incident_id>#EVENT#<timestamp>#<event_type>
```

Ví dụ:

```text
PK = TENANT#tenant-a
SK = INCIDENT#inc-001#EVENT#2026-06-24T10:00:00Z#AI_DIAGNOSIS_COMPLETED
```

Lợi ích:

- query được toàn bộ lifecycle của một incident;
- query theo tenant;
- hỗ trợ evidence cho mentor;
- hỗ trợ compliance/audit review.

## 7. S3 audit archive design

S3 dùng để lưu audit record dài hạn:

```text
s3://triage-hub-audit/tenant_id=tenant-a/year=2026/month=06/day=24/incident_id=inc-001/audit.json
```

S3 nên bật:

- SSE-KMS;
- bucket versioning nếu cần;
- lifecycle policy;
- block public access.

## 8. Trace correlation

Mỗi alert nên có một `trace_id` duy nhất. `trace_id` phải đi qua toàn bộ pipeline:

```text
API Gateway
→ EventBridge
→ Lambda Context Aggregator
→ AI Endpoint
→ Jira Connector
→ Slack Connector
→ Audit Writer
```

Điều này giúp khi debug có thể tìm toàn bộ log/audit của cùng một incident.

## 9. Mapping audit với Jira ticket

Jira ticket nên có field/link:

```text
incident_id
trace_id
ai_decision_id
confidence_score
audit_record_link hoặc audit_reference
```

Nhờ vậy khi mở Jira ticket, mentor/team có thể truy ngược lại AI decision và alert ban đầu.

## 10. Mapping audit với Slack notification

Slack message nên có:

```text
incident_id
service_name
severity
confidence_score
jira_ticket_url
action button: Acknowledge
```

Khi user click acknowledge, hệ thống ghi audit event:

```text
ACKNOWLEDGED
```

với thông tin:

```text
acknowledged_by
acknowledged_at
slack_message_id
incident_id
trace_id
```

## 11. Failure audit

Nếu Jira, Slack hoặc AI endpoint lỗi, hệ thống vẫn phải ghi audit event:

```json
{
  "event_type": "FAILED_EVENT_RECORDED",
  "status": "FAILED",
  "failed_component": "JIRA_CONNECTOR",
  "error_message": "Jira API timeout",
  "retry_count": 3
}
```

Failure audit rất quan trọng để chứng minh hệ thống không mất dấu incident khi downstream service lỗi.

## 12. Test cases

| ID | Test case | Kết quả mong muốn |
|---|---|---|
| AUD-01 | Gửi alert hợp lệ | Có `ALERT_RECEIVED`. |
| AUD-02 | Tenant valid | Có `TENANT_VALIDATED`. |
| AUD-03 | Gọi AI thành công | Có `AI_DIAGNOSIS_REQUESTED` và `AI_DIAGNOSIS_COMPLETED`. |
| AUD-04 | Tạo Jira ticket | Có `JIRA_TICKET_CREATED` với ticket ID. |
| AUD-05 | Gửi Slack | Có `SLACK_NOTIFICATION_SENT` với message ID. |
| AUD-06 | User acknowledge | Có `ACKNOWLEDGED`. |
| AUD-07 | Jira API lỗi | Có `FAILED_EVENT_RECORDED`. |

## 13. Acceptance Criteria

Điều kiện hoàn thành:

- Mọi bước chính trong pipeline đều có audit event.
- Audit record có `tenant_id`, `incident_id`, `trace_id`.
- AI decision liên kết được với Jira ticket và Slack notification.
- Có failure audit khi service downstream lỗi.
- Audit storage dùng DynamoDB/S3 và được mã hóa.
- Có documentation, ADR và diagram trong repo.
