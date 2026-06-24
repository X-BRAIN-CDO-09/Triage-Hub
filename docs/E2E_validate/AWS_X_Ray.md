# AWS X-Ray Traceability Guide

## Mục tiêu

Thiết lập khả năng truy vết (Traceability) xuyên suốt toàn bộ luồng xử lý của Triage Hub:

```text
Alert
  ↓
API Gateway
  ↓
Lambda (Context Collector)
  ↓
AI Engine (Bedrock)
  ↓
Jira Integration
  ↓
Slack Integration
```

Mục tiêu cuối cùng:

* Theo dõi toàn bộ vòng đời của một Alert
* Xác định bottleneck hoặc lỗi tại từng bước
* Hỗ trợ Root Cause Analysis
* Hỗ trợ E2E Validation và Incident Investigation

---

# Kiến trúc Trace

```text
Alert Received
      │
      ▼
API Gateway
      │
      ▼
Lambda: Alert Processor
      │
      ▼
Lambda: Context Collector
      │
      ▼
Bedrock AI Analysis
      │
      ▼
Jira Ticket Creation
      │
      ▼
Slack Notification
```

Mỗi request sẽ có:

```text
Trace ID
```

Ví dụ:

```text
1-68a123bc-123456789abcdef123456789
```

---

# Bước 1 – Bật X-Ray cho API Gateway

## AWS Console

API Gateway

```text
Stages
    ↓
prod
    ↓
Logs & Tracing
```

Bật:

```text
Enable X-Ray Tracing
```

Lưu cấu hình.

---

## AWS CLI

```bash
aws apigateway update-stage \
  --rest-api-id <api-id> \
  --stage-name prod \
  --patch-operations \
    op=replace,path=/tracingEnabled,value=true
```

Kiểm tra:

```bash
aws apigateway get-stage \
  --rest-api-id <api-id> \
  --stage-name prod
```

Kết quả:

```json
{
  "tracingEnabled": true
}
```

---

# Bước 2 – Bật X-Ray cho Lambda

## Context Collector Lambda

```bash
aws lambda update-function-configuration \
  --function-name triage-context-collector \
  --tracing-config Mode=Active
```

---

## AI Engine Lambda

```bash
aws lambda update-function-configuration \
  --function-name triage-ai-engine \
  --tracing-config Mode=Active
```

---

## Jira Integration Lambda

```bash
aws lambda update-function-configuration \
  --function-name triage-jira-integration \
  --tracing-config Mode=Active
```

---

## Slack Integration Lambda

```bash
aws lambda update-function-configuration \
  --function-name triage-slack-notifier \
  --tracing-config Mode=Active
```

---

# Bước 3 – Cấp quyền IAM

Thêm policy:

```json
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect":"Allow",
      "Action":[
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords"
      ],
      "Resource":"*"
    }
  ]
}
```

AWS Managed Policy:

```text
AWSXRayDaemonWriteAccess
```

---

# Bước 4 – Propagate Trace ID

## Lambda Handler

Ví dụ Python:

```python
from aws_xray_sdk.core import patch_all
from aws_xray_sdk.core import xray_recorder

patch_all()

def handler(event, context):

    segment = xray_recorder.current_segment()

    trace_id = segment.trace_id

    print(f"Trace ID: {trace_id}")

    return {
        "trace_id": trace_id
    }
```

---

# Bước 5 – Gắn Trace ID vào Jira

Khi tạo Ticket:

```json
{
  "summary": "Critical Incident",
  "description": "Trace ID: 1-68a123bc-123456789abcdef123456789"
}
```

Ví dụ Description:

```text
Incident Analysis

Classification:
CRITICAL_INCIDENT

Confidence:
0.92

Trace ID:
1-68a123bc-123456789abcdef123456789
```

---

# Bước 6 – Gắn Trace ID vào Slack

Ví dụ Notification:

```text
🚨 Critical Incident

Service:
Customer API

Classification:
CRITICAL_INCIDENT

Trace ID:
1-68a123bc-123456789abcdef123456789
```

Kỹ sư On-call có thể dùng Trace ID để truy vết.

---

# Bước 7 – Gắn Trace ID vào DynamoDB Audit

Ví dụ Item:

```json
{
  "alert_id":"ALERT-001",
  "trace_id":"1-68a123bc-123456789abcdef123456789",
  "classification":"CRITICAL_INCIDENT",
  "severity":"CRITICAL"
}
```

---

# Bước 8 – Kiểm tra X-Ray Service Map

AWS Console

```text
AWS X-Ray
    ↓
Service Map
```

Kết quả mong đợi:

```text
API Gateway
      ↓
Alert Processor
      ↓
Context Collector
      ↓
AI Engine
      ↓
Jira Integration
      ↓
Slack Integration
```

---

# Validation Test

## Test Case

Tạo Alert:

```text
Critical Incident
```

Kiểm tra:

### API Gateway

```text
Trace Generated
```

### Lambda

```text
Trace Continued
```

### Jira

```text
Trace ID Present
```

### Slack

```text
Trace ID Present
```

### DynamoDB

```text
Trace ID Present
```

---

# Acceptance Criteria

| Hạng mục                          | Kết quả mong đợi |
| --------------------------------- | ---------------- |
| API Gateway tạo Trace             | PASS             |
| Lambda nhận Trace                 | PASS             |
| AI Engine nhận Trace              | PASS             |
| Jira chứa Trace ID                | PASS             |
| Slack chứa Trace ID               | PASS             |
| DynamoDB lưu Trace ID             | PASS             |
| X-Ray Service Map hiển thị đầy đủ | PASS             |

---

# Evidence Collection

## Evidence 1

AWS X-Ray Service Map

```text
01-xray-service-map.png
```

---

## Evidence 2

Lambda Trace

```text
02-lambda-trace.png
```

---

## Evidence 3

Jira Ticket

```text
03-jira-trace-id.png
```

---

## Evidence 4

Slack Notification

```text
04-slack-trace-id.png
```

---

## Evidence 5

DynamoDB Audit

```text
05-dynamodb-trace-id.png
```

---

# Kết luận

Sau khi hoàn thành cấu hình, mỗi Alert sẽ được gắn một Trace ID duy nhất và có thể được truy vết xuyên suốt từ API Gateway → Lambda → AI Engine → Jira → Slack → Audit Trail bằng AWS X-Ray. Điều này giúp tăng khả năng điều tra sự cố, giảm thời gian MTTR và đáp ứng yêu cầu traceability của hệ thống Triage Hub.
