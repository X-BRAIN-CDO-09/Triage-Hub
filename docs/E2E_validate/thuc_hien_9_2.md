# Story 9.2 – Latency Degradation Scenario

## Chaos Engineering Execution Guide (ArgoCD / GitOps Friendly)

### Mục tiêu

Mô phỏng tình huống dịch vụ vẫn hoạt động nhưng phản hồi rất chậm.

Mục tiêu xác thực:

```text
Latency tăng
↓
Alert sinh ra
↓
AI phân tích
↓
Jira Ticket
↓
Slack Notification
↓
Audit Trail
```

Dịch vụ không được down hoàn toàn.

---

# Phương án được khuyến nghị

## Method 1 – CPU Stress (Khuyến nghị nhất)

### Lý do

* Không sửa Git
* Không gây drift ArgoCD
* Không cần redeploy
* Dễ rollback

---

### Bước 1 – Xác định Pod

```bash
kubectl get pods -n app
```

Ví dụ:

```text
api-5d8c8b9f7f-xj2kl
```

---

### Bước 2 – Exec vào Pod

```bash
kubectl exec -it api-5d8c8b9f7f-xj2kl -- sh
```

---

### Bước 3 – Chạy CPU Stress

Nếu image có stress-ng:

```bash
stress-ng --cpu 4 --timeout 300s
```

Nếu không có:

```bash
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
```

---

### Bước 4 – Sinh Traffic

Từ máy local:

```bash
hey -n 5000 -c 50 https://api.example.com
```

hoặc

```bash
k6 run load-test.js
```

---

### Kết quả mong đợi

```text
CPU > 80%
Response Time tăng
P95 > 2000ms
```

---

### Alert mong đợi

```text
High API Latency
```

---

### AI mong đợi

```json
{
  "classification":"LATENCY_DEGRADATION",
  "confidence":0.85
}
```

---

### Cleanup

Kill process:

```bash
pkill stress-ng
```

hoặc

```bash
pkill yes
```

---

# Method 2 – Network Latency Injection

## Lý do

Gần với thực tế production hơn.

---

### Bước 1

Exec vào Pod:

```bash
kubectl exec -it api-pod -- sh
```

---

### Bước 2

Thêm delay mạng:

```bash
tc qdisc add dev eth0 root netem delay 2000ms
```

---

### Bước 3

Kiểm tra:

```bash
curl https://api.example.com
```

---

### Kết quả

```text
Response tăng thêm ~2s
```

---

### Alert

```text
P95 Latency > SLO
```

---

### AI

```json
{
  "classification":"LATENCY_DEGRADATION",
  "root_cause":"Network latency"
}
```

---

### Cleanup

```bash
tc qdisc del dev eth0 root
```

---

# Method 3 – Database Slow Query

## Lý do

Thực tế nhất với hệ thống doanh nghiệp.

---

### Bước 1

Tạo query chậm.

Ví dụ PostgreSQL:

```sql
SELECT pg_sleep(5);
```

---

### Bước 2

API gọi query này liên tục.

---

### Kết quả

```text
Database Response Time tăng
Application Response Time tăng
```

---

### Alert

```text
Database Latency High
```

---

### AI

```json
{
  "classification":"LATENCY_DEGRADATION",
  "root_cause":"Database latency"
}
```

---

# Checklist Evidence

## Evidence 1

CloudWatch Dashboard

Chụp:

```text
P95 Latency
CPU
Request Rate
```

---

## Evidence 2

Prometheus Alert

```text
Latency Alert = FIRING
```

---

## Evidence 3

AI Analysis

```json
{
  "classification":"LATENCY_DEGRADATION",
  "confidence":"0.80+"
}
```

---

## Evidence 4

Jira Ticket

```text
[MEDIUM] Latency Degradation
```

---

## Evidence 5

Slack Notification

```text
Performance Alert
```

---

## Evidence 6

Audit Record

```text
classification
confidence
tenant
timestamp
```

---

# Kết quả mong đợi

| Hạng mục                          | Kết quả |
| --------------------------------- | ------- |
| Service vẫn hoạt động             | PASS    |
| Latency tăng vượt SLO             | PASS    |
| Alert được sinh                   | PASS    |
| AI nhận diện đúng                 | PASS    |
| Jira Ticket tạo thành công        | PASS    |
| Slack Notification gửi thành công | PASS    |
| Audit Trail được lưu              | PASS    |

## Kết luận

Kịch bản đạt yêu cầu khi hệ thống vẫn phục vụ request nhưng độ trễ vượt ngưỡng SLO, Alert được kích hoạt và toàn bộ luồng Alert → AI → Jira → Slack hoạt động thành công.
