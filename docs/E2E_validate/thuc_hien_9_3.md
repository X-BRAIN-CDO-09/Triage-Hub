# Story 9.3 – False Positive Scenario

## Chaos Engineering Execution Guide (ArgoCD-Friendly)

### Mục tiêu

Mô phỏng một cảnh báo nhiễu (False Positive / Noisy Alert) được sinh ra từ hệ thống Monitoring nhưng không có đủ bằng chứng để xác định nguyên nhân gốc rễ.

Mục tiêu xác thực:

```text
Noisy Alert
      ↓
Prometheus Alert
      ↓
Triage Hub
      ↓
AI Analysis
      ↓
INVESTIGATE
      ↓
Jira Ticket
      ↓
Slack Notification
```

AI phải:

* Không đoán mò nguyên nhân
* Không Hallucination
* Trả về Confidence thấp
* Sinh nhãn INVESTIGATE
* Yêu cầu con người kiểm tra thủ công

---

# Method 1 – CPU Spike Ngắn Hạn (Khuyến nghị)

## Lý do lựa chọn

* Tạo Alert thật từ Prometheus
* Không gây downtime
* Không ảnh hưởng ArgoCD
* Dễ rollback
* Dễ chứng minh False Positive

---

## Bước 1 – Kiểm tra trạng thái ban đầu

```bash
kubectl get pods -A
```

Kiểm tra Health:

```bash
curl https://<app-url>/health
```

Kết quả:

```text
HTTP 200 OK
```

### Evidence

Tên file:

```text
01-system-healthy-before-test.png
```

---

## Bước 2 – Xác nhận Alert Rule

Ví dụ:

```yaml
alert: HighCPUUsage
expr: cpu_usage > 90
for: 1s
```

Mục tiêu:

```text
CPU vượt ngưỡng trong thời gian rất ngắn
```

---

## Bước 3 – Chọn Pod mục tiêu

```bash
kubectl get pods -n app
```

Ví dụ:

```text
api-7f86fdb8cf-2txwx
```

---

## Bước 4 – Tạo CPU Spike Thực Tế

Exec vào Pod:

```bash
kubectl exec -it api-7f86fdb8cf-2txwx -- sh
```

Sinh tải CPU:

```bash
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
```

Chạy khoảng:

```text
2–3 giây
```

Sau đó dừng ngay:

```bash
pkill yes
```

---

## Bước 5 – Xác minh hệ thống vẫn khỏe mạnh

Kiểm tra:

```bash
curl https://<app-url>/health
```

Kết quả:

```text
HTTP 200 OK
```

Kiểm tra Pod:

```bash
kubectl get pods -n app
```

Kết quả:

```text
Running
Ready
```

---

## Bước 6 – Xác minh Alert được sinh

Prometheus:

```text
HighCPUUsage
```

Trạng thái:

```text
FIRING
```

Sau vài giây:

```text
RESOLVED
```

### Evidence

Tên file:

```text
02-prometheus-false-positive-alert.png
```

---

## Bước 7 – Xác minh Context Collection

Triage Hub thu thập:

### Metrics

```text
CPU tăng đột biến
```

### Logs

```text
Không có Error
Không có Exception
Không có Restart
```

### Deployment

```text
Không có rollout mới
```

### Availability

```text
100%
```

---

## Bước 8 – Kiểm tra AI Analysis

AI phải nhận biết:

```text
Dữ liệu không đủ để kết luận
```

Response mong đợi:

```json
{
  "classification":"INVESTIGATE",
  "confidence":0.32,
  "root_cause":"UNKNOWN",
  "recommendation":"Manual investigation required."
}
```

---

## Acceptance Criteria

### Classification

```text
INVESTIGATE
```

### Confidence

```text
< 0.50
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
Memory Leak
Database Failure
Network Issue
Pod Scheduling Problem
```

Nếu AI trả về các giá trị trên:

```text
FAIL
```

(Hallucination)

---

## Evidence

Tên file:

```text
03-ai-investigate-response.png
```

---

## Bước 9 – Kiểm tra Jira Ticket

Summary mong đợi:

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
Insufficient evidence for root cause determination.

Manual investigation required.
```

### Không được chứa

```text
Root Cause: Database Failure
Root Cause: Memory Leak
Root Cause: Network Issue
```

### Evidence

Tên file:

```text
04-jira-investigate-ticket.png
```

---

## Bước 10 – Kiểm tra Slack Notification

Notification mong đợi:

```text
⚠️ Investigation Required

Alert:
CPU Spike

Classification:
INVESTIGATE

Confidence:
0.32

Reason:
Insufficient supporting evidence.
```

Phải xuất hiện:

```text
[Acknowledge]
```

### Evidence

Tên file:

```text
05-slack-investigate-alert.png
```

---

## Bước 11 – Kiểm tra Audit Trail

```bash
aws dynamodb get-item \
--table-name triage-audit
```

Kết quả mong đợi:

```text
classification = INVESTIGATE
confidence < 0.50
```

### Evidence

Tên file:

```text
06-audit-trail-investigate.png
```

---

## Validation Sau Test

Kiểm tra:

```bash
curl https://<app-url>/health
```

Kết quả:

```text
HTTP 200 OK
```

Kiểm tra Pod:

```bash
kubectl get pods -n app
```

Tất cả Pod:

```text
Running
Ready
```

---

# PASS Criteria

| Hạng mục                    | Kết quả mong đợi |
| --------------------------- | ---------------- |
| Alert thật được sinh        | PASS             |
| Hệ thống không downtime     | PASS             |
| Không có Error Log          | PASS             |
| AI trả INVESTIGATE          | PASS             |
| Confidence < 0.50           | PASS             |
| Không Hallucination         | PASS             |
| Jira Ticket được tạo        | PASS             |
| Slack Notification được gửi | PASS             |
| Audit Trail được lưu        | PASS             |

---

# Kết luận

Kịch bản đạt yêu cầu khi Alert được sinh ra từ một CPU Spike ngắn hạn, hệ thống vẫn hoạt động bình thường, AI từ chối suy đoán nguyên nhân gốc rễ và trả về nhãn INVESTIGATE với độ tin cậy thấp để yêu cầu con người kiểm tra thủ công.
