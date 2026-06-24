# Story 9.1 – Critical Incident Scenario

## Chaos Engineering Execution Guide (ArgoCD-Friendly)

### Mục tiêu

Mô phỏng một sự cố thực tế khiến ứng dụng không thể phục vụ người dùng để kiểm chứng toàn bộ luồng:

```text
Application Failure
        ↓
Prometheus Alert
        ↓
Triage Hub
        ↓
AI Analysis
        ↓
Jira Ticket
        ↓
Slack Notification
        ↓
Engineer Acknowledge
```

---

# Method 1 – Database Disconnect (Khuyến nghị)

## Lý do lựa chọn

* Không gây drift với ArgoCD
* Dễ rollback
* Sinh ra lỗi thực tế giống Production
* Dễ tạo Alert Critical
* AI dễ xác định Root Cause

---

## Bước 1 – Kiểm tra trạng thái ban đầu

Kiểm tra Pod:

```bash
kubectl get pods -A
```

Kiểm tra Service:

```bash
kubectl get svc -A
```

Kết quả mong đợi:

```text
Application = Running
Database = Running
```

---

## Bước 2 – Xác nhận ứng dụng hoạt động bình thường

Kiểm tra Health Endpoint:

```bash
curl https://<app-url>/health
```

Kết quả:

```text
HTTP/1.1 200 OK
```

### Evidence

Chụp màn hình:

* Health Check thành công
* Thời gian thực hiện

Tên file:

```text
01-before-failure-healthcheck.png
```

---

## Bước 3 – Xác định Database Endpoint

Ví dụ:

```bash
kubectl get svc -A
```

hoặc

```bash
aws rds describe-db-instances
```

Thông tin cần xác định:

```text
Database Endpoint
Port
Security Group
```

Ví dụ:

```text
postgres-rds.amazonaws.com
Port: 5432
```

---

## Bước 4 – Chặn kết nối Database

### Trường hợp sử dụng RDS

Thu hồi rule cho phép kết nối:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 5432
```

### Trường hợp Database chạy trong Kubernetes

Tạo file:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-db
  namespace: app
spec:
  podSelector:
    matchLabels:
      app: api

  policyTypes:
    - Egress

  egress: []
```

Apply:

```bash
kubectl apply -f deny-db.yaml
```

---

## Bước 5 – Xác minh ứng dụng gặp lỗi

Thực hiện request:

```bash
curl https://<app-url>/api/users
```

Kết quả mong đợi:

```text
500 Internal Server Error
```

hoặc

```text
503 Service Unavailable
```

---

## Bước 6 – Kiểm tra Application Logs

```bash
kubectl logs deployment/api -n app
```

Kết quả mong đợi:

```text
Connection timeout
Database unavailable
Failed to connect database
```

### Evidence

Tên file:

```text
02-db-connection-failure-log.png
```

---

## Bước 7 – Xác minh Monitoring Alert

Kiểm tra Prometheus:

```bash
kubectl port-forward svc/prometheus 9090 -n monitoring
```

Kiểm tra Alert:

```text
High Error Rate
Service Down
Database Connectivity Failure
```

Trạng thái:

```text
FIRING
```

### Evidence

Tên file:

```text
03-prometheus-critical-alert.png
```

---

## Bước 8 – Xác minh Alert vào Triage Hub

Kiểm tra:

```text
Alert ID
Timestamp
Tenant ID
Severity
```

Kết quả mong đợi:

```text
Severity = Critical
```

---

## Bước 9 – Kiểm tra AI Analysis

Response mong đợi:

```json
{
  "classification":"CRITICAL_INCIDENT",
  "severity":"CRITICAL",
  "confidence":0.90,
  "root_cause":"Database connectivity failure"
}
```

### Acceptance Criteria

* Classification = CRITICAL_INCIDENT
* Severity = CRITICAL
* Confidence >= 0.80
* Root Cause hợp lý

### Evidence

Tên file:

```text
04-ai-critical-analysis.png
```

---

## Bước 10 – Kiểm tra Jira Ticket

Summary mong đợi:

```text
[P1][CRITICAL] Service Down - tenant-a
```

Labels:

```text
critical
incident
p1
tenant-a
```

Priority:

```text
Highest
```

### Evidence

Tên file:

```text
05-jira-critical-ticket.png
```

---

## Bước 11 – Kiểm tra Slack Notification

Notification mong đợi:

```text
🚨 CRITICAL INCIDENT

Severity: CRITICAL

Root Cause:
Database connectivity failure
```

Phải xuất hiện nút:

```text
[Acknowledge]
```

### Evidence

Tên file:

```text
06-slack-critical-alert.png
```

---

## Bước 12 – Kiểm tra Audit Trail

Kiểm tra DynamoDB:

```bash
aws dynamodb get-item \
--table-name triage-audit
```

Kết quả mong đợi:

```text
classification = CRITICAL_INCIDENT
severity = CRITICAL
```

### Evidence

Tên file:

```text
07-audit-trail-critical.png
```

---

## Bước 13 – Khôi phục hệ thống

### Nếu sử dụng NetworkPolicy

```bash
kubectl delete networkpolicy deny-db -n app
```

### Nếu sử dụng Security Group

Khôi phục rule:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 5432 \
  --cidr <allowed-cidr>
```

---

## Validation Sau Recovery

Kiểm tra:

```bash
curl https://<app-url>/health
```

Kết quả mong đợi:

```text
HTTP/1.1 200 OK
```

Kiểm tra Pod:

```bash
kubectl get pods -n app
```

Tất cả Pod phải ở trạng thái:

```text
Running
Ready
```

---

# PASS Criteria

| Hạng mục                       | Kết quả mong đợi |
| ------------------------------ | ---------------- |
| Service bị ảnh hưởng thực tế   | PASS             |
| Alert Critical được sinh       | PASS             |
| AI phân loại CRITICAL_INCIDENT | PASS             |
| Severity = CRITICAL            | PASS             |
| Confidence >= 0.80             | PASS             |
| Jira Ticket P1 được tạo        | PASS             |
| Slack Notification được gửi    | PASS             |
| Acknowledge hoạt động          | PASS             |
| Audit Trail được lưu           | PASS             |
| Hệ thống phục hồi thành công   | PASS             |

---

# Kết luận

Kịch bản được đánh giá PASS khi việc ngắt kết nối Database làm ứng dụng phát sinh lỗi thực tế, Alert Critical được kích hoạt và toàn bộ luồng E2E từ Alert → AI → Jira → Slack → Audit Trail hoạt động đúng như thiết kế.
