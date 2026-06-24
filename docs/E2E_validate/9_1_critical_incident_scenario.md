# TC-E2E-09.1-001 – Kiểm thử E2E: Critical Incident Scenario

## 1. Thông tin Test Case

| Thuộc tính          | Giá trị                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Test Case ID        | TC-E2E-09.1-001                                                                                                                                  |
| Feature             | E2E Validation                                                                                                                                   |
| Story               | Story 9.1 – Critical Incident Scenario                                                                                                           |
| Loại kiểm thử       | End-to-End + Chaos Engineering                                                                                                                   |
| Mức độ ưu tiên      | Rất cao (P1)                                                                                                                                     |
| Môi trường          | AWS Dev/Test                                                                                                                                     |
| Người phụ trách     | Chaos Engineering / SRE                                                                                                                          |
| Mục tiêu            | Xác minh Triage Hub có khả năng phát hiện, phân tích và xử lý hoàn chỉnh một sự cố nghiêm trọng (Critical Incident) từ Alert → AI → Jira → Slack |
| Tiêu chí thành công | AI xác định đúng mức độ nghiêm trọng, đưa ra Root Cause có cơ sở, tạo Jira Ticket P1 và gửi Slack Notification đến đúng Team Owner               |

---

# 2. Mô tả kịch bản

## Bối cảnh nghiệp vụ

Một dịch vụ quan trọng của hệ thống gặp sự cố và không còn phục vụ người dùng.

Ví dụ:

* API trả về HTTP 500 liên tục
* ECS Task Crash Loop
* Lambda liên tục timeout
* Database không thể kết nối
* Kubernetes Pod liên tục Restart

Tác động:

* Người dùng không thể truy cập hệ thống
* Error Rate tăng đột biến
* SLO/SLA bị vi phạm

Trong trường hợp này hệ thống phải:

✅ Phát hiện Alert Critical

✅ Thu thập đầy đủ Logs và Metrics

✅ AI phân tích nguyên nhân tiềm năng

✅ Đánh giá mức độ ảnh hưởng

✅ Tự động tạo Jira Ticket mức P1

✅ Gửi Slack Notification khẩn cấp

✅ Cho phép On-call Engineer xác nhận xử lý bằng nút Acknowledge

---

# 3. Điều kiện tiên quyết (Pre-conditions)

## Hạ tầng

### API Gateway

Endpoint nhận Alert hoạt động:

```text
POST /v1/alerts
```

### AI Engine

AI Engine ở trạng thái Healthy:

```bash
aws lambda get-function \
  --function-name triage-ai-engine
```

Kết quả mong đợi:

```text
State: Active
```

### CloudWatch

Đang thu thập:

```text
CPU Utilization
Memory Utilization
Error Rate
Request Count
Response Time
Availability
```

### DynamoDB

Bảng Audit tồn tại:

```text
triage-audit
```

### Jira

Project:

```text
TRIAGE
```

### Slack

Channel tiếp nhận:

```text
#platform-team
```

### Tenant Routing

```json
{
  "tenant-a": {
    "jira_project": "TRIAGE",
    "team_owner": "#platform-team"
  }
}
```

---

# 4. Bước gây lỗi (Failure Injection)

## Mục tiêu

Tạo ra một sự cố thực sự khiến dịch vụ không thể phục vụ người dùng.

---

## Phương pháp 1 – Kill Application Process

Ví dụ trên ECS EC2:

```bash
pkill -9 node
```

hoặc:

```bash
kill -9 <PID>
```

Kết quả:

```text
Application Down
Health Check Failed
HTTP 500 Errors
```

---

## Phương pháp 2 – Chặn Database

Ví dụ Security Group:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id sg-xxxx \
  --protocol tcp \
  --port 5432
```

Kết quả:

```text
Application mất kết nối Database
```

---

## Phương pháp 3 – ECS Task Failure

Scale về 0:

```bash
aws ecs update-service \
  --cluster prod \
  --service api-service \
  --desired-count 0
```

Kết quả:

```text
Service Unavailable
```

---

## Phương pháp 4 – Kubernetes

Xóa toàn bộ Pod:

```bash
kubectl delete pod -l app=api
```

hoặc:

```bash
kubectl scale deployment api --replicas=0
```

---

# 5. Các bước thực hiện và kết quả mong đợi

## Luồng E2E

```text
Critical Alert
      ↓
API Gateway
      ↓
Context Collection
      ↓
AI Engine
      ↓
Root Cause Analysis
      ↓
P1 Jira Ticket
      ↓
Slack Notification
      ↓
Engineer Acknowledge
```

---

## Bảng kiểm thử

| Bước | Thao tác                  | Kết quả mong đợi                  |
| ---- | ------------------------- | --------------------------------- |
| 1    | Gây lỗi hệ thống          | Service ngừng hoạt động           |
| 2    | Monitoring phát hiện      | Alert Critical được sinh ra       |
| 3    | Alert gửi vào Triage Hub  | API Gateway nhận thành công       |
| 4    | Context Collector chạy    | Thu thập Logs và Metrics          |
| 5    | AI Engine được gọi        | Request thành công                |
| 6    | AI phân tích dữ liệu      | Xác định Incident nghiêm trọng    |
| 7    | AI sinh Root Cause        | Có nguyên nhân hợp lý             |
| 8    | AI đánh giá Severity      | CRITICAL                          |
| 9    | Jira Ticket được tạo      | Priority P1                       |
| 10   | Slack Notification gửi đi | Team Owner nhận được cảnh báo     |
| 11   | Audit Trail được ghi nhận | DynamoDB lưu dữ liệu              |
| 12   | Engineer Acknowledge      | Trạng thái Incident được cập nhật |

---

# 6. Kiểm thử AI Engine

## Response mong đợi

```json
{
  "classification":"CRITICAL_INCIDENT",
  "confidence":0.94,
  "severity":"CRITICAL",
  "root_cause":"Database connectivity failure",
  "recommendation":"Restore database connectivity immediately. Check security groups and database health.",
  "impact":"Users unable to access application.",
  "reasoning":"Error rate increased to 100%, availability dropped to 0%, and database connection failures appeared in application logs."
}
```

---

## Điều kiện PASS

### Classification

```text
CRITICAL_INCIDENT
```

### Severity

```text
CRITICAL
```

### Confidence

```text
confidence >= 0.80
```

### Root Cause

Phải dựa trên bằng chứng thực tế:

Ví dụ hợp lệ:

```text
Database connectivity failure
Application crash
Lambda timeout
Pod crash loop
```

Không được trả kết quả mơ hồ:

```text
Unknown issue
System problem
Potential error
```

---

# 7. Kiểm thử Jira

## Summary mong đợi

```text
[P1][CRITICAL] Service Down - tenant-a
```

---

## Labels

```text
critical
p1
incident
tenant-a
ai-generated
```

---

## Description

```text
AI Diagnosis

Classification:
CRITICAL_INCIDENT

Severity:
CRITICAL

Confidence:
0.94

Potential Root Cause:
Database connectivity failure

Impact:
Users unable to access service.

Recommended Action:

1. Verify database health.
2. Verify network connectivity.
3. Restore service availability.
```

---

## Priority

```text
Highest
```

hoặc

```text
P1
```

---

# 8. Kiểm thử Slack

## Notification mong đợi

```text
🚨 CRITICAL INCIDENT

Tenant:
tenant-a

Service:
Customer Portal API

Severity:
CRITICAL

Confidence:
0.94

Potential Root Cause:
Database connectivity failure

Impact:
Users unable to access application.

Action Required:
Immediate response required.
```

---

## Routing Validation

Notification phải đến:

```text
#platform-team
```

---

## Acknowledge Button

Notification phải chứa:

```text
[Acknowledge]
```

Engineer nhấn nút này phải:

```text
Incident Status = Acknowledged
```

---

# 9. Kiểm thử Audit Trail

Kiểm tra DynamoDB:

```bash
aws dynamodb get-item \
--table-name triage-audit \
--key '{"alert_id":{"S":"ALERT-CRIT-001"}}'
```

Kết quả mong đợi:

```json
{
  "alert_id":"ALERT-CRIT-001",
  "tenant_id":"tenant-a",
  "classification":"CRITICAL_INCIDENT",
  "severity":"CRITICAL",
  "confidence":"0.94"
}
```

---

# 10. Kiểm thử Observability

## CloudWatch Logs

Phải xuất hiện:

```text
Critical Alert Received
Context Aggregated
AI Invoked
Critical Incident Detected
Jira Created
Slack Sent
Incident Acknowledged
```

---

## CloudWatch Dashboard

Các Metric phải tăng:

```text
Critical Incidents +1
P1 Tickets Created +1
Slack Notifications Sent +1
Acknowledged Incidents +1
```

---

# 11. Hướng dẫn thu thập bằng chứng (Evidence Collection)

## Evidence 1 – Failure Injection

Chụp:

* Lệnh gây lỗi
* Trạng thái Service Down

Tên file:

```text
critical-failure-injection.png
```

---

## Evidence 2 – Monitoring Alert

Chụp:

* Alert Firing
* Severity Critical

Tên file:

```text
critical-alert-fired.png
```

---

## Evidence 3 – CloudWatch Metrics

Chụp biểu đồ:

```text
Availability
Error Rate
Request Count
```

Tên file:

```text
critical-metrics-dashboard.png
```

---

## Evidence 4 – AI Response

Chụp JSON Response:

```json
{
  "classification":"CRITICAL_INCIDENT",
  "severity":"CRITICAL",
  "confidence":"0.94"
}
```

Tên file:

```text
ai-critical-analysis.png
```

---

## Evidence 5 – Jira Ticket

Chụp:

* Ticket ID
* Severity
* Root Cause
* Confidence

Tên file:

```text
jira-critical-ticket.png
```

---

## Evidence 6 – Slack Notification

Chụp:

* Notification
* Severity
* Acknowledge Button

Tên file:

```text
slack-critical-alert.png
```

---

## Evidence 7 – Audit Trail

Chụp DynamoDB Record:

```text
alert_id
classification
severity
confidence
tenant_id
```

Tên file:

```text
audit-trail-critical.png
```

---

# Kết quả nghiệm thu

| Yêu cầu                         | Kết quả mong đợi | PASS/FAIL |
| ------------------------------- | ---------------- | --------- |
| Alert Critical được phát hiện   | Có               | PASS      |
| AI phân loại CRITICAL_INCIDENT  | Có               | PASS      |
| Severity = CRITICAL             | Có               | PASS      |
| Confidence >= 0.80              | Có               | PASS      |
| Jira Ticket P1 được tạo         | Có               | PASS      |
| Slack Notification được gửi     | Có               | PASS      |
| Đúng Team Owner                 | Có               | PASS      |
| Audit Trail được lưu            | Có               | PASS      |
| Engineer Acknowledge thành công | Có               | PASS      |
| Quan sát được trên Dashboard    | Có               | PASS      |

## Kết luận

**Test Case được đánh giá PASS khi toàn bộ các tiêu chí trên đều đạt yêu cầu và hệ thống hoàn thành đầy đủ luồng E2E từ Alert → AI Analysis → Jira → Slack → Acknowledge.**
