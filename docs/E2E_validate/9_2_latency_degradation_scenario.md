# TC-E2E-09.2-001 – Kiểm thử E2E: Latency Degradation Scenario

## 1. Thông tin Test Case

| Thuộc tính          | Giá trị                                                                                                                                                                             |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Test Case ID        | TC-E2E-09.2-001                                                                                                                                                                     |
| Feature             | E2E Validation                                                                                                                                                                      |
| Story               | Story 9.2 – Latency Degradation Scenario                                                                                                                                            |
| Loại kiểm thử       | End-to-End + Chaos Engineering                                                                                                                                                      |
| Mức độ ưu tiên      | Cao                                                                                                                                                                                 |
| Môi trường          | AWS Dev/Test                                                                                                                                                                        |
| Người phụ trách     | Chaos Engineering / SRE                                                                                                                                                             |
| Mục tiêu            | Xác minh Triage Hub có thể phát hiện hiện tượng suy giảm hiệu năng (Latency Degradation), AI xác định đúng nguyên nhân tiềm năng và tự động tạo Jira Ticket cùng Slack Notification |
| Tiêu chí thành công | AI sinh Root Cause hợp lý, Confidence Score đạt ngưỡng, Jira Ticket được tạo tự động, Slack Notification được gửi đến đúng Team Owner                                               |

---

# 2. Mô tả kịch bản

## Bối cảnh nghiệp vụ

Một dịch vụ vẫn hoạt động bình thường nhưng thời gian phản hồi tăng cao bất thường.

Ví dụ:

* API Response Time tăng từ 100ms lên 2500ms
* P95 Latency vượt SLO trong nhiều phút
* Request Queue tăng liên tục
* CPU vẫn bình thường nhưng Database Response Time tăng

Tình huống này chưa phải Service Down nhưng ảnh hưởng trực tiếp tới trải nghiệm người dùng.

AI cần:

✅ Thu thập Metrics liên quan

✅ Phân tích Logs

✅ Kiểm tra Deployment gần nhất

✅ Đề xuất nguyên nhân có khả năng cao

✅ Tạo Jira Ticket với mức Severity phù hợp

✅ Gửi Slack Notification tới đúng Team Owner

---

# 3. Điều kiện tiên quyết (Pre-conditions)

## Hạ tầng

### API Gateway

Endpoint tiếp nhận Alert hoạt động:

```text
POST /v1/alerts
```

### AI Engine

AI Engine đang hoạt động bình thường:

```bash
aws lambda get-function \
  --function-name triage-ai-engine
```

Kết quả mong đợi:

```text
State: Active
```

### CloudWatch Metrics

Các Metrics phải được thu thập:

```text
Latency
P95 Latency
Request Count
Error Rate
CPU Utilization
Memory Utilization
```

### DynamoDB

Bảng audit:

```text
triage-audit
```

### Jira

Project:

```text
TRIAGE
```

### Slack

Notification Channel:

```text
#platform-team
```

---

# 4. Bước gây lỗi (Failure Injection)

## Mục tiêu

Giả lập hiện tượng tăng độ trễ của ứng dụng nhưng không làm Service Down.

---

## Phương pháp 1 – Delay API Response

Nếu ứng dụng chạy trên ECS/Lambda:

Thêm delay giả lập:

```javascript
await new Promise(resolve => setTimeout(resolve, 3000));
```

Mỗi request sẽ bị chậm khoảng 3 giây.

---

## Phương pháp 2 – Dùng Toxiproxy

Tạo network latency:

```bash
toxiproxy-cli toxic add app-db \
  -t latency \
  -a latency=3000
```

Kết quả:

```text
Database Response Time +3000ms
```

---

## Phương pháp 3 – Stress CPU

```bash
stress-ng --cpu 4 --timeout 120s
```

Mục tiêu:

```text
P95 Latency > 2000ms
```

---

# 5. Các bước thực hiện và kết quả mong đợi

## Luồng E2E

```text
Latency Alert
      ↓
API Gateway
      ↓
Context Collection
      ↓
AI Engine
      ↓
Root Cause Analysis
      ↓
Jira Ticket
      ↓
Slack Notification
```

---

## Bảng kiểm thử

| Bước | Thao tác                  | Kết quả mong đợi                     |
| ---- | ------------------------- | ------------------------------------ |
| 1    | Inject Latency            | Monitoring phát hiện bất thường      |
| 2    | Alert được gửi            | API Gateway nhận Alert               |
| 3    | Thu thập Metrics          | P95 Latency tăng mạnh                |
| 4    | Thu thập Logs             | Không có Service Crash               |
| 5    | Kiểm tra Deployment       | Có hoặc không có deployment gần đây  |
| 6    | AI Engine phân tích       | Xác định khả năng suy giảm hiệu năng |
| 7    | AI tính Confidence        | Confidence > Threshold               |
| 8    | AI sinh Root Cause        | Có nguyên nhân khả thi               |
| 9    | Jira Ticket được tạo      | Ticket chứa phân tích AI             |
| 10   | Slack Notification gửi đi | Team Owner nhận được cảnh báo        |
| 11   | Audit Trail được lưu      | DynamoDB ghi nhận đầy đủ             |
| 12   | Dashboard cập nhật        | Counter Latency Incident tăng        |

---

# 6. Kiểm thử AI Engine

## Response mong đợi

```json
{
  "classification":"LATENCY_DEGRADATION",
  "confidence":0.88,
  "severity":"MEDIUM",
  "root_cause":"Database response latency increased significantly",
  "recommendation":"Investigate database performance and slow queries.",
  "reasoning":"P95 latency increased from 120ms to 2400ms. Database response time increased by 15x while CPU and memory remained stable."
}
```

---

## Điều kiện PASS

### Confidence

```text
confidence >= 0.70
```

### Classification

```text
LATENCY_DEGRADATION
```

### Severity

```text
MEDIUM
```

hoặc

```text
HIGH
```

---

## Recommendation

Phải có hành động cụ thể:

```text
Check slow queries
Review database performance
Check connection pool
Review recent deployment
```

Không được trả lời chung chung:

```text
Please investigate
Something is wrong
```

---

# 7. Kiểm thử Jira

## Summary mong đợi

```text
[MEDIUM] Latency Degradation - tenant-a
```

---

## Labels

```text
latency
performance
tenant-a
ai-generated
```

---

## Description

```text
AI Diagnosis:

Database response latency increased significantly.

Confidence:
0.88

Impact:
User-facing API response time exceeded SLO.

Recommended actions:

1. Check slow queries.
2. Review connection pool saturation.
3. Review recent deployment changes.
```

---

# 8. Kiểm thử Slack

## Notification mong đợi

```text
⚠️ Triage Hub Performance Alert

Tenant:
tenant-a

Alert:
Latency Degradation

Severity:
MEDIUM

Confidence:
0.88

Potential Root Cause:
Database latency increased

Recommended Action:
Check slow queries and connection pool.
```

---

## Routing Validation

Notification phải đến:

```text
#platform-team
```

---

## Acknowledge Button

Phải hiển thị:

```text
[Acknowledge]
```

và hoạt động bình thường.

---

# 9. Kiểm thử Audit Trail

Truy vấn:

```bash
aws dynamodb get-item \
--table-name triage-audit \
--key '{"alert_id":{"S":"ALERT-LAT-001"}}'
```

Kết quả mong đợi:

```json
{
  "alert_id":"ALERT-LAT-001",
  "tenant_id":"tenant-a",
  "classification":"LATENCY_DEGRADATION",
  "confidence":"0.88",
  "severity":"MEDIUM"
}
```

---

# 10. Kiểm thử Observability

## CloudWatch Logs

Phải xuất hiện:

```text
Alert Received
Metrics Collected
AI Invoked
Latency Degradation Detected
Jira Created
Slack Sent
```

---

## CloudWatch Dashboard

Các Metric tăng:

```text
Latency Incidents +1
AI Diagnosed Incidents +1
Jira Tickets Created +1
```

---

# 11. Hướng dẫn thu thập bằng chứng (Evidence Collection)

## Evidence 1 – Latency Injection

Chụp:

* Lệnh stress-ng hoặc toxiproxy
* Metric Latency tăng

Tên file:

```text
latency-injection.png
```

---

## Evidence 2 – CloudWatch Metrics

Chụp biểu đồ:

```text
P95 Latency
Request Count
Error Rate
```

Tên file:

```text
cloudwatch-latency-spike.png
```

---

## Evidence 3 – AI Response

Chụp JSON Response:

```json
{
  "classification":"LATENCY_DEGRADATION",
  "confidence":"0.88"
}
```

Tên file:

```text
ai-latency-diagnosis.png
```

---

## Evidence 4 – Jira Ticket

Chụp:

* Ticket ID
* Root Cause
* Confidence Score
* Recommendation

Tên file:

```text
jira-latency-ticket.png
```

---

## Evidence 5 – Slack Notification

Chụp:

* Severity
* Confidence
* Root Cause
* Acknowledge Button

Tên file:

```text
slack-latency-alert.png
```

---

## Evidence 6 – Audit Trail

Chụp bản ghi DynamoDB:

```text
alert_id
classification
confidence
severity
tenant_id
```

Tên file:

```text
audit-trail-latency.png
```

---

# Kết quả nghiệm thu

| Yêu cầu                              | Kết quả mong đợi | PASS/FAIL |
| ------------------------------------ | ---------------- | --------- |
| Alert được xử lý E2E                 | Có               | PASS      |
| AI xác định đúng Latency Degradation | Có               | PASS      |
| Confidence >= 0.70                   | Có               | PASS      |
| Root Cause hợp lý                    | Có               | PASS      |
| Jira Ticket được tạo                 | Có               | PASS      |
| Slack Notification được gửi          | Có               | PASS      |
| Đúng Team Owner                      | Có               | PASS      |
| Audit Trail được lưu                 | Có               | PASS      |
| Quan sát được trên Dashboard         | Có               | PASS      |

## Kết luận

**Test Case được đánh giá PASS khi toàn bộ các tiêu chí trên đều đạt yêu cầu và AI đưa ra chẩn đoán có cơ sở dựa trên dữ liệu thực tế thay vì suy đoán.**
