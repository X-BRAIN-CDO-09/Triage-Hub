# TC-E2E-09.3-001 – Kiểm thử E2E: Cảnh báo giả (False Positive / Noisy Alert)

## 1. Thông tin Test Case

| Thuộc tính          | Giá trị                                                                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Test Case ID        | TC-E2E-09.3-001                                                                                                                                 |
| Feature             | E2E Validation                                                                                                                                  |
| Story               | Story 9.3 – False Positive Scenario                                                                                                             |
| Loại kiểm thử       | End-to-End + Chaos Engineering                                                                                                                  |
| Mức độ ưu tiên      | Cao                                                                                                                                             |
| Môi trường          | AWS Dev/Test                                                                                                                                    |
| Người phụ trách     | Chaos Engineering / SRE                                                                                                                         |
| Mục tiêu            | Xác minh Triage Hub nhận diện đúng cảnh báo nhiễu và không tạo ra kết luận sai                                                                  |
| Tiêu chí thành công | AI trả về nhãn INVESTIGATE với độ tin cậy thấp, Jira Ticket được tạo mà không có chẩn đoán sai, Slack Notification được gửi đến đúng team owner |

---

# 2. Mô tả kịch bản

## Bối cảnh nghiệp vụ

Một bất thường tạm thời xảy ra trên hạ tầng nhưng tự phục hồi ngay lập tức.

Ví dụ:

* CPU tăng đột biến trong 1 giây
* Latency tăng ngắn hạn rồi trở lại bình thường
* Alert kiểm thử không có log lỗi tương ứng
* Alert giả lập từ hệ thống monitoring

Hệ thống phải tránh:

❌ Bịa ra nguyên nhân gốc rễ (Root Cause)

❌ Kết luận sai rằng dịch vụ đang gặp sự cố

❌ Tự động phân loại thành Critical Incident

Thay vào đó hệ thống phải:

✅ Nhận biết dữ liệu không đủ để kết luận

✅ Trả về Confidence Score thấp

✅ Sinh khuyến nghị INVESTIGATE

✅ Tạo Jira Ticket phục vụ điều tra

✅ Gửi thông báo đến đúng team chịu trách nhiệm

---

# 3. Điều kiện tiên quyết (Pre-conditions)

## Hạ tầng

### API Gateway

Endpoint tiếp nhận Alert phải hoạt động:

```text
POST /v1/alerts
```

### AI Engine

AI Engine đã được triển khai và ở trạng thái Healthy:

```bash
aws lambda get-function \
  --function-name triage-ai-engine
```

Kết quả mong đợi:

```text
State: Active
```

### DynamoDB

Bảng audit tồn tại:

```text
triage-audit
```

Các trường dữ liệu bắt buộc:

```json
{
  "alert_id":"",
  "tenant_id":"",
  "confidence":"",
  "classification":"",
  "jira_ticket":"",
  "slack_notification":""
}
```

### Bedrock

Role của AI Engine có quyền Invoke Model.

### Secrets Manager

Đã cấu hình các secret:

```text
jira-api-token
slack-webhook
bedrock-api-key
```

### Jira

Service Account có quyền:

```text
Create Issue
Add Labels
Add Comments
```

Project dùng để test:

```text
TRIAGE
```

### Slack

Slack App đã được cài đặt và có quyền:

```text
chat:write
incoming-webhook
interactive-components
```

### Tenant Routing

Đã cấu hình ánh xạ tenant:

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

Tạo một cảnh báo nhiễu nhưng không có bằng chứng hỗ trợ để AI không thể kết luận nguyên nhân.

---

## Phương pháp 1 – Gửi Alert giả lập qua API Gateway

```bash
curl -X POST https://api.triagehub.com/v1/alerts \
-H "Content-Type: application/json" \
-d '{
  "alert_id":"ALERT-FP-001",
  "tenant_id":"tenant-a",
  "severity":"warning",
  "alert_name":"CPU Spike",
  "metric":"cpu_usage",
  "value":92,
  "threshold":90,
  "duration_seconds":1,
  "timestamp":"2026-06-23T10:00:00Z"
}'
```

### Lý do đây là Alert nhiễu

```text
CPU > 90%
Chỉ kéo dài 1 giây
Không có log lỗi
Không có deployment gần đây
Không có crash
Không có tăng latency
```

AI phải đánh giá đây là:

```text
INSUFFICIENT EVIDENCE
```

(Dữ liệu không đủ để kết luận)

---

## Phương pháp 2 – Giả lập Alert từ Prometheus

Rule kiểm thử:

```yaml
groups:
- name: false-positive-test
  rules:
  - alert: CpuSpikeNoise
    expr: cpu_usage > 90
    for: 1s
    labels:
      severity: warning
```

Sinh tải CPU:

```bash
stress-ng --cpu 1 --timeout 1s
```

Alert sẽ xuất hiện rồi tự biến mất gần như ngay lập tức.

---

# 5. Các bước thực hiện và kết quả mong đợi

## Luồng E2E

```text
Noisy Alert
      ↓
API Gateway
      ↓
Context Collection
      ↓
AI Engine
      ↓
INVESTIGATE
      ↓
Jira Ticket
      ↓
Slack Notification
```

---

## Bảng kiểm thử

| Bước | Thao tác                     | Kết quả mong đợi                  |
| ---- | ---------------------------- | --------------------------------- |
| 1    | Inject Alert nhiễu           | API Gateway nhận Alert thành công |
| 2    | Thu thập Logs                | Không phát hiện lỗi nghiêm trọng  |
| 3    | Thu thập Metrics             | Chỉ thấy spike ngắn hạn           |
| 4    | Kiểm tra Deployment gần nhất | Không có deployment mới           |
| 5    | Gọi AI Engine                | Request tới AI thành công         |
| 6    | AI phân tích dữ liệu         | Xác định dữ liệu không đủ         |
| 7    | AI tính Confidence           | Confidence thấp hơn ngưỡng        |
| 8    | AI sinh kết quả              | Classification = INVESTIGATE      |
| 9    | Tạo Jira Ticket              | Ticket được tạo thành công        |
| 10   | Gửi Slack Notification       | Notification được gửi             |
| 11   | Lưu Audit Trail              | Dữ liệu được ghi vào DynamoDB     |
| 12   | Dashboard cập nhật           | Counter INVESTIGATE tăng thêm 1   |

---

# 6. Kiểm thử AI Engine

## Response mong đợi

```json
{
  "classification":"INVESTIGATE",
  "confidence":0.32,
  "root_cause":"UNKNOWN",
  "recommendation":"Insufficient evidence detected. Manual investigation recommended.",
  "reasoning":"Transient CPU spike observed without supporting logs, deployment events, or service degradation."
}
```

## Điều kiện PASS

### Confidence thấp

```text
confidence < 0.50
```

### Root Cause

Được phép:

```text
UNKNOWN
INSUFFICIENT_DATA
NOT_ENOUGH_CONTEXT
```

Không được phép:

```text
Database Failure
Memory Leak
Network Issue
Kubernetes Scheduling Problem
```

Nếu AI trả các giá trị trên thì xem là Hallucination.

### Recommendation

Phải chứa:

```text
INVESTIGATE
```

hoặc:

```text
Manual Investigation Required
```

---

# 7. Kiểm thử Jira

## Ticket mong đợi

Summary:

```text
[INVESTIGATE] CPU Spike - tenant-a
```

Labels:

```text
investigate
false-positive
low-confidence
tenant-a
```

Description:

```text
Alert received.

AI confidence score: 0.32

Evidence insufficient for root-cause determination.

Recommended action:
Manual investigation required.
```

Không được chứa:

```text
Root Cause: Database Failure
Root Cause: Memory Leak
Root Cause: Service Down
```

---

# 8. Kiểm thử Slack

## Nội dung Notification mong đợi

```text
⚠️ Triage Hub Investigation Required

Tenant: tenant-a

Alert:
CPU Spike

Confidence:
0.32

Classification:
INVESTIGATE

Reason:
Insufficient supporting evidence.

Action:
Please review manually.
```

### Kiểm tra Routing

Notification phải đến:

```text
#platform-team
```

Không được gửi tới:

```text
#payments-team
#security-team
```

### Nút Acknowledge

Phải xuất hiện:

```text
[Acknowledge]
```

và hoạt động bình thường.

---

# 9. Kiểm thử Audit Trail

Truy vấn DynamoDB:

```bash
aws dynamodb get-item \
--table-name triage-audit \
--key '{"alert_id":{"S":"ALERT-FP-001"}}'
```

Kết quả mong đợi:

```json
{
  "alert_id":"ALERT-FP-001",
  "tenant_id":"tenant-a",
  "classification":"INVESTIGATE",
  "confidence":"0.32"
}
```

---

# 10. Kiểm thử Observability

## CloudWatch Logs

Phải xuất hiện chuỗi log:

```text
Alert Received
Context Aggregated
AI Invoked
Low Confidence Detected
INVESTIGATE Generated
Jira Created
Slack Sent
```

## CloudWatch Dashboard

Các metric phải tăng:

```text
Investigate Incidents +1
False Positive Alerts +1
AI Low Confidence Events +1
```

---

# 11. Hướng dẫn thu thập bằng chứng (Evidence Collection)

## Evidence 1 – Inject Alert

Chụp:

* Lệnh curl
* HTTP 200 Response
* Alert ID

Tên file:

```text
alert-injected.png
```

---

## Evidence 2 – AI Decision

Chụp JSON response:

```json
{
  "classification":"INVESTIGATE",
  "confidence":"<0.50"
}
```

Tên file:

```text
ai-investigate-response.png
```

---

## Evidence 3 – CloudWatch Logs

Chụp log hiển thị:

```text
Alert Received
Context Aggregated
Low Confidence
INVESTIGATE
```

Tên file:

```text
cloudwatch-investigate-flow.png
```

---

## Evidence 4 – Jira Ticket

Chụp:

* Ticket ID
* Labels
* Description
* Confidence Score

Tên file:

```text
jira-investigate-ticket.png
```

---

## Evidence 5 – Slack Notification

Chụp:

* Channel nhận thông báo
* Classification
* Confidence
* Nút Acknowledge

Tên file:

```text
slack-investigate-alert.png
```

---

## Evidence 6 – Audit Trail

Chụp bản ghi DynamoDB:

```text
alert_id
tenant_id
classification
confidence
timestamp
```

Tên file:

```text
audit-trail-investigate.png
```

---

# Kết quả nghiệm thu

| Yêu cầu                           | Kết quả mong đợi     | PASS/FAIL |
| --------------------------------- | -------------------- | --------- |
| Confidence thấp                   | Confidence < 0.50    | PASS      |
| Không Hallucination               | Root Cause = UNKNOWN | PASS      |
| Có nhãn INVESTIGATE               | Có                   | PASS      |
| Jira Ticket được tạo              | Có                   | PASS      |
| Không có chẩn đoán sai trong Jira | Có                   | PASS      |
| Slack Notification được gửi       | Có                   | PASS      |
| Đúng Team Owner                   | Có                   | PASS      |
| Audit Trail được lưu              | Có                   | PASS      |
| Quan sát được trên CloudWatch     | Có                   | PASS      |

## Kết luận

**Test Case được đánh giá PASS khi toàn bộ 9 tiêu chí trên đều đạt yêu cầu.**
