# Tổng Quan Hệ Thống Observability & Hướng Dẫn Kiểm Tra

Tài liệu này mô tả **chính xác** kiến trúc Observability đang được triển khai trong dự án Triage-Hub, dựa trên code Terraform và source code thực tế. Bao gồm giải thích ý nghĩa từng chỉ số (metric), tên tài nguyên thật trên AWS, và hướng dẫn kiểm tra từng bước.

---

## 1. Tổng Quan Kiến Trúc Observability

Hệ thống Observability gồm **5 lớp** giám sát được triển khai thực tế:

| Lớp | Công nghệ | Trạng thái |
|-----|-----------|-----------|
| CloudWatch Dashboard | `triage-hub-dashboard-sandbox` | ✅ Deployed |
| CloudWatch Metric Alarms | Per-component, SNS notify | ✅ Deployed |
| SNS Topic | `triage-hub-alerts-sandbox` | ✅ Deployed (nếu `enable_notifications = true`) |
| Application Metrics (Prometheus) | `prometheus_client` trong AI Engine | ✅ Deployed |
| Distributed Tracing (OpenTelemetry) | OTLP → Jaeger (tùy cấu hình) | ✅ Deployed |

### Luồng dữ liệu thực tế (Data Flow)

```
EC2 Customer App
  ↓ HTTP POST /alerts (API Key required)
API Gateway (triage-hub-apigw-sandbox)
  ↓ SQS Direct Integration (VTL template)
raw-alert-queue.fifo  ←── FIFO queue, dedup by content
  ↓ ESM (batch_size=1)
Lambda: alert-ingest
  ↓ sqs:SendMessage
buffer-queue.fifo     ←── KEDA scales Worker by ApproximateNumberOfMessagesVisible
  ↓ EKS Worker Pod (tf1-worker)
AI Engine (FastAPI) via Internal ALB
  ↓ EventBridge (IncidentAssigned)
broadcast-notifier Lambda → Slack
  +
  ↓ sqs:SendMessage
dispatch-queue        ←── ESM (batch_size=10)
Lambda: notify-dispatcher → Jira + Slack
```

---

## 2. Tài Nguyên AWS Thực Tế (Sandbox)

### SQS Queues (3 queues)

| Tên Queue | Loại | Mục đích | Cấu hình đặc biệt |
|-----------|------|----------|-------------------|
| `triage-hub-raw-alert-queue.fifo` | FIFO | Nhận alert từ API Gateway | `visibility_timeout=60s`, `retention=4 ngày`, `max_receive_count=5`, content-based dedup |
| `triage-hub-buffer-queue.fifo` | FIFO | Buffer cho AI Engine Worker | FIFO + content-based dedup |
| `triage-hub-dispatch-queue` | Standard | Gửi kết quả đến notify-dispatcher | Standard queue |

### Lambda Functions (4 functions)

| Function Name | Runtime | Trigger | Env Vars chính |
|---------------|---------|---------|----------------|
| `triage-hub-alert-ingest` | nodejs20.x | ESM từ `raw-alert-queue.fifo` (batch=1) | `SQS_QUEUE_URL`, `DYNAMODB_TABLE` |
| `triage-hub-jira-dispatcher` | nodejs20.x | API Gateway POST /slack | `DYNAMODB_TABLE`, `JIRA_SECRET_ARN`, `SLACK_SIGNING_SECRET_ARN`, `SLACK_BOT_TOKEN_ARN`, `EVENT_BUS_NAME` |
| `triage-hub-broadcast-notifier` | nodejs20.x | EventBridge (IncidentAssigned) | `SLACK_BOT_TOKEN_ARN` |
| `triage-hub-notify-dispatcher` | nodejs20.x | ESM từ `dispatch-queue` (batch=10) | `DYNAMODB_TABLE`, `JIRA_SECRET_ARN`, `SLACK_BOT_TOKEN_ARN`, `JIRA_DISPATCHER_ARN` |

### API Gateway

- **Tên**: `triage-hub-apigw-sandbox`
- **Endpoint 1**: `POST /alerts` — API Key bắt buộc → SQS Direct Integration → `raw-alert-queue.fifo`
- **Endpoint 2**: `POST /slack` — Không cần API Key → Lambda Proxy → `jira-dispatcher`

### EventBridge

- **Event Bus**: `triage-hub-event-bus-sandbox`
- **Rule**: `triage-hub-jira-assigned-rule-sandbox`
  - Source: `triage-hub.jira`, DetailType: `IncidentAssigned`
  - Target: Lambda `broadcast-notifier`

### EKS Cluster

- **Cluster**: `triage-hub-eks-sandbox`
- **Scaler**: KEDA `ScaledObject` → `tf1-worker-scaler` theo `buffer-queue.fifo` depth
- **AI Engine**: FastAPI Pod `tf1-api` + Worker Pod `tf1-worker`
- **ALB**: Internal ALB → TargetGroup binding cho `tf1-api`

---

## 3. CloudWatch Dashboard — Bố Cục Thực Tế

Dashboard tên: **`triage-hub-dashboard-sandbox`**

Cấu trúc widget theo code `modules/observability/main.tf`:

### Section 1 — Health Overview (Y: 0–8)

8 widget dạng `singleValue` hiển thị tổng quan tức thì:

| Widget | Metric | Ý nghĩa |
|--------|--------|---------|
| API Request Count | `AWS/ApiGateway > Count (Sum)` | Tổng số request đến API |
| API Latency (p99) | `AWS/ApiGateway > Latency (p99)` | 99th percentile latency |
| Lambda Errors | `SUM(Errors)` tất cả Lambda | Tổng lỗi Lambda |
| Lambda Duration | `AVG(Duration)` tất cả Lambda | Thời gian thực thi trung bình |
| Queue Depth | `MAX(ApproximateNumberOfMessagesVisible)` | Độ sâu hàng đợi lớn nhất |
| Oldest Message Age | `MAX(ApproximateAgeOfOldestMessage)` | Tin nhắn cũ nhất đang chờ |
| DynamoDB Throttled | `AWS/DynamoDB > ThrottledRequests (Sum)` | Số request DynamoDB bị giới hạn |
| Overall Error Rate | `(Errors/Invocations) * 100` qua Math Expression | Tỷ lệ lỗi tổng thể (%) |

### Section 2 — End-to-End Processing Pipeline (Y: 9–15)

6 widget `timeSeries` theo dõi dòng chảy xử lý từng bước:

```
1. API Requests → 2. Alert Ingest (Lambda) → 3. Buffer Queue →
4. Dispatcher (Lambda) → 5. Dispatch Queue → 6. Notify & DynamoDB
```

### Section 3 — Detailed Service Metrics (Y: 16+)

Các widget chi tiết theo thứ tự:

1. **API Gateway** (full): Count, 4XX, 5XX, Latency p99, IntegrationLatency, CacheHit/Miss
2. **Lambda mỗi function**: Invocations, Errors, Throttles, ConcurrentExecutions, Duration (Avg/Max), IteratorAge, Success Rate %, Error Rate %
3. **SQS mỗi queue**: Sent, Received, Visible, OldestAge, NotVisible, Deleted, EmptyReceives
4. **DynamoDB**: ReadCapacity, WriteCapacity, SystemErrors, Latency, Throttled, UserErrors, ConditionalCheckFailed
5. **EKS Container Insights**: `node_cpu_utilization`, `node_memory_utilization`, `pod_number_of_container_restarts`, `node_status_condition_ready`
6. **Internal ALB**: RequestCount, HTTPCode_Target_5XX, HTTPCode_ELB_5XX, TargetResponseTime
7. **Customer App EC2**: CPUUtilization, NetworkIn, NetworkOut

### Section 4 — CloudWatch Logs Insights

4 widget tự động query log từ tất cả Lambda (`/aws/lambda/triage-hub-*`):

| Widget | View |
|--------|------|
| Top Error Messages (filter ERROR/Error/Exception, stats count by message, limit 10) | table |
| Error Trend (cùng filter, stats count by bin(5m)) | timeSeries |
| Slowest Lambda Invocations (filter @type=REPORT, sort @duration desc, limit 10) | table |
| Top Exception Types (parse Exception, stats count by exc) | table |

### Section 5 — System Alarms Status

Widget `alarm` tổng hợp tất cả Alarms đang được cấu hình.

### Section 6 — Cost Monitoring & ServiceLens

- **Cost Widget**: `AWS/Billing > EstimatedCharges (USD)` — period 6 giờ (us-east-1)
- **ServiceLens Link**: Deep-link trực tiếp vào CloudWatch ServiceLens Map

---

## 4. CloudWatch Alarms — Chi Tiết Triển Khai

Tất cả Alarms: `evaluation_periods = 2`, `period = 60s`

### API Gateway Alarms

| Alarm Name | Metric | Threshold mặc định |
|------------|--------|---------------------|
| `triage-hub-apigw-latency-high` | Latency p99 | 2000ms |
| `triage-hub-apigw-4xx-high` | 4XXError Sum | 5 |
| `triage-hub-apigw-5xx-high` | 5XXError Sum | 1 |

### Lambda Alarms (per function: alert-ingest, jira-dispatcher, notify-dispatcher)

| Pattern | Metric | Threshold mặc định | Ghi chú |
|---------|--------|---------------------|---------|
| `{func}-error-rate-high` | `Errors/Invocations * 100` | 5% | Math Expression composite alarm |
| `{func}-duration-high` | Duration Average | 5000ms | |
| `{func}-throttles-high` | Throttles Sum | 1 | |

### SQS Alarms (per queue: raw-alert-queue.fifo, buffer-queue.fifo, dispatch-queue)

| Pattern | Metric | Threshold mặc định |
|---------|--------|---------------------|
| `{queue}-queue-depth-high` | ApproximateNumberOfMessagesVisible Max | 1000 tin nhắn |
| `{queue}-oldest-message-high` | ApproximateAgeOfOldestMessage Max | 3600 giây |

### DynamoDB Alarms

| Alarm Name | Metric | Threshold mặc định |
|------------|--------|---------------------|
| `{table}-throttles-high` | ThrottledRequests Sum | 10 |
| `{table}-system-errors-high` | SystemErrors Sum | 1 |

### ALB Alarms (khi `monitor_alb = true`)

| Alarm Name | Metric | Threshold mặc định |
|------------|--------|---------------------|
| `triage-hub-alb-5xx-high` | HTTPCode_Target_5XX_Count Sum | 5 |
| `triage-hub-alb-latency-high` | TargetResponseTime Average | 2 giây |

### EC2 Alarm (khi `monitor_ec2 = true`)

| Alarm Name | Metric | Threshold mặc định |
|------------|--------|---------------------|
| `triage-hub-ec2-cpu-high` | CPUUtilization Average | 80% |

> **Cấu hình thresholds**: Override qua variable `alarm_thresholds` trong `environments/sandbox/terraform.tfvars`.

---

## 5. Application-Level Observability (AI Engine)

AI Engine (`tf1-ai-triage-engine`) tự phát sinh metrics qua `prometheus_client`, expose tại `/metrics`.

### Custom Prometheus Metrics (19 metrics)

| Metric | Loại | Labels | Ý nghĩa |
|--------|------|--------|---------|
| `aiops_triage_requests_total` | Counter | `status`, `classification` | Tổng triage requests theo trạng thái |
| `aiops_triage_request_duration_seconds` | Histogram | — | Thời gian xử lý triage end-to-end |
| `aiops_triage_inflight_requests` | Gauge | — | Số request đang xử lý đồng thời |
| `aiops_context_tool_calls_total` | Counter | `tool`, `status` | Lần gọi từng context tool |
| `aiops_context_tool_duration_seconds` | Histogram | `tool` | Thời gian gọi từng tool |
| `aiops_llm_calls_total` | Counter | `stage`, `model`, `status` | Lần gọi LLM (Bedrock) |
| `aiops_llm_tokens_total` | Counter | `stage`, `model`, `type` | Ước tính token tiêu thụ |
| `aiops_llm_estimated_cost_usd_total` | Counter | `stage`, `model` | Ước tính chi phí LLM (USD) |
| `aiops_circuit_breaker_open` | Gauge | `dependency` | Trạng thái circuit breaker (0=closed, 1=open) |
| `aiops_budget_exceeded_total` | Counter | `budget_type` | Số lần vượt quá budget |
| `aiops_degraded_mode_total` | Counter | `reason` | Số lần chạy ở degraded mode |
| `aiops_investigation_mode_selected_total` | Counter | `mode`, `source` | Investigation mode được chọn |
| `aiops_idempotency_events_total` | Counter | `result` | Kết quả idempotency check |
| `aiops_triage_rejected_total` | Counter | `reason` | Requests bị từ chối |
| `aiops_evidence_truncation_total` | Counter | `type`, `reason` | Evidence bị compact/truncate |
| `aiops_qa_iterations_total` | Counter | `result` | QA judge iterations |
| `aiops_agent_iterations_total` | Counter | `result` | Agent platform iterations |
| `aiops_agent_tool_requests_total` | Counter | `tool`, `status` | Agent tool requests |
| `aiops_agent_fallback_total` | Counter | `reason` | Agent deterministic fallbacks |

### Distributed Tracing (OpenTelemetry)

- **Tracer**: `aiops.engine`
- **Spans**: `context_tool_call` (attributes: `tool`, `tenant_id`, `environment`, `service`)
- **Exporter**: OTLPSpanExporter → env `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
- **Log format**: JSON structured, fields sanitize theo `AIOPS_LOG_POLICY=metadata_only`

### Context Tools Backend

| Tool | Backend | Env Var |
|------|---------|---------|
| `get_metrics` | Prometheus | `PROMETHEUS_URL` |
| `get_logs` | Loki | `LOKI_URL` |
| `get_traces` | Jaeger | `JAEGER_URL` |
| `search_known_errors` | File JSON | `KNOWN_ERRORS_PATH` |
| `get_jira_history` | DynamoDB | `DYNAMODB_TABLE` |

---

## 6. Hướng Dẫn Từng Bước Kiểm Tra & Xác Thực

### Bước 1: Xác nhận SNS Subscription

1. Sau `terraform apply`, AWS SNS gửi email đến địa chỉ `var.notification_email`.
2. Mở email **AWS Notifications - Subscription Confirmation**.
3. Nhấn **Confirm subscription** → Trang hiển thị "Subscription confirmed!".

```bash
# Kiểm tra subscription hiện tại
aws sns list-subscriptions-by-topic --topic-arn <arn> --region us-east-1
```

### Bước 2: Kiểm tra Dashboard

1. AWS Console → **CloudWatch** → **Dashboards** → **`triage-hub-dashboard-sandbox`**
2. Kiểm tra 8 widget Health Overview có data (không phải "No data")
3. Cuối Dashboard: widget Logs Insights — log lỗi hiện theo bảng

### Bước 3: Test Alarm bằng CLI (không gây lỗi thật)

```bash
# Ép trạng thái ALARM → nhận email trong 10-15 giây
aws cloudwatch set-alarm-state \
    --alarm-name "triage-hub-apigw-5xx-high" \
    --state-value ALARM \
    --state-reason "Kiểm tra hệ thống gửi Email Alert" \
    --region us-east-1

# Đưa về OK sau khi test
aws cloudwatch set-alarm-state \
    --alarm-name "triage-hub-apigw-5xx-high" \
    --state-value OK \
    --state-reason "Đã hoàn thành bài test" \
    --region us-east-1
```

### Bước 4: End-to-End Test với dữ liệu thật

**Lấy URL và API Key:**
```bash
cd capstone/tf-1/devops/infra/environments/sandbox
terraform output apigw_invoke_url
terraform output api_key_value
```

**Test 1: Gửi alert hợp lệ**
```bash
API_URL="https://<id>.execute-api.us-east-1.amazonaws.com/prod"
API_KEY="<your_api_key>"

curl -X POST "$API_URL/alerts" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -H "X-Tenant-Id: tenant-a" \
  -H "X-Correlation-Id: test-$(date +%s)" \
  -d '{
    "schema_version": "tf1.incident_seed.v1",
    "tenant_id": "tenant-a",
    "incident_id": "INC-TEST-001",
    "correlation_id": "test-001",
    "environment": "sandbox",
    "service": "payment-service",
    "severity": "high",
    "title": "High latency detected",
    "started_at": "2026-07-01T00:00:00Z",
    "received_at": "2026-07-01T00:00:00Z"
  }'
```

**Xác minh**: Dashboard → Widget "2. Alert Ingest" tăng 1 Invocation.

**Test 2: Kiểm tra SQS Queue Depth**
```bash
aws sqs get-queue-attributes \
  --queue-url "https://sqs.us-east-1.amazonaws.com/730335441285/triage-hub-raw-alert-queue.fifo" \
  --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage \
  --region us-east-1
```

**Test 3: Test Log lỗi (payload sai)**
```bash
curl -X POST "$API_URL/alerts" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"invalid_field": "test_log"}'
```

Query log:
```
# CloudWatch Logs Insights → /aws/lambda/triage-hub-alert-ingest
fields @timestamp, @message
| filter @message like /Error|Exception|invalid/
| sort @timestamp desc
| limit 20
```

**Test 4: Kiểm tra EventBridge**
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name Invocations \
  --dimensions Name=EventBusName,Value=triage-hub-event-bus-sandbox \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum --region us-east-1
```

**Test 5: AI Engine metrics (Prometheus)**
```bash
kubectl port-forward -n triage-hub deploy/tf1-api 8080:8080
curl http://localhost:8080/metrics | grep aiops_
```

**Test 6: EC2 CPU Alarm**
```bash
# SSH vào customer-app EC2, chạy stress test
yes > /dev/null & yes > /dev/null & yes > /dev/null &
# Sau 2-3 phút alarm kích hoạt. Cleanup:
killall yes
```

**Test 7: Container Insights EKS**
- CloudWatch → Insights → Container Insights → Cluster `triage-hub-eks-sandbox`

---

## 7. Kiểm Tra Prometheus Dynamic Discovery

Terraform tự động lấy IP của EC2 Prometheus và lưu vào SSM:

```bash
aws ssm get-parameter \
  --name "/triage-hub/sandbox/prometheus_ip" \
  --region us-east-1 \
  --query "Parameter.Value" --output text
```

AI Engine dùng `PROMETHEUS_URL=http://<ip>:9090` để query:
```promql
aiops_scenario_metric_value{tenant_id="tenant-a",environment="sandbox",service="payment-service"}
```

---

## 8. Danh Sách Alarm Names Thực Tế (Sandbox)

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "triage-hub" \
  --region us-east-1 \
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" \
  --output table
```

**Tổng cộng ~22 alarms:**

```
# API Gateway (3)
triage-hub-apigw-latency-high
triage-hub-apigw-4xx-high
triage-hub-apigw-5xx-high

# Lambda x3 functions x3 types = 9 alarms
triage-hub-alert-ingest-error-rate-high
triage-hub-alert-ingest-duration-high
triage-hub-alert-ingest-throttles-high
triage-hub-jira-dispatcher-error-rate-high
triage-hub-jira-dispatcher-duration-high
triage-hub-jira-dispatcher-throttles-high
triage-hub-notify-dispatcher-error-rate-high
triage-hub-notify-dispatcher-duration-high
triage-hub-notify-dispatcher-throttles-high

# SQS x3 queues x2 types = 6 alarms
triage-hub-raw-alert-queue.fifo-queue-depth-high
triage-hub-raw-alert-queue.fifo-oldest-message-high
triage-hub-buffer-queue.fifo-queue-depth-high
triage-hub-buffer-queue.fifo-oldest-message-high
triage-hub-dispatch-queue-queue-depth-high
triage-hub-dispatch-queue-oldest-message-high

# DynamoDB (2)
triage-hub-incidents-sandbox-throttles-high
triage-hub-incidents-sandbox-system-errors-high

# ALB (2)
triage-hub-alb-5xx-high
triage-hub-alb-latency-high

# EC2 (1)
triage-hub-ec2-cpu-high
```

---

## 9. Troubleshooting Thường Gặp

### Alarm ở `INSUFFICIENT_DATA`

**Nguyên nhân**: Metric chưa có data points (resource mới tạo hoặc chưa có traffic).

```bash
aws cloudwatch describe-alarms --alarm-names "triage-hub-apigw-5xx-high" --region us-east-1
```

**Giải pháp**: Gửi vài request để kích hoạt metrics, chờ 2–3 phút.

### Lambda Error Rate alarm nhạy quá

Alarm dùng Math Expression `IF(m2 == 0, 0, m1/m2 * 100)` — chỉ báo khi có invocations. Điều chỉnh qua `alarm_thresholds.lambda_error_rate`.

### SQS FIFO Queue Depth không giảm

```bash
# Kiểm tra Lambda trigger
aws lambda list-event-source-mappings --function-name triage-hub-alert-ingest --region us-east-1
```

Nếu `State: Disabled` → Enable lại trigger.

### AI Engine metrics không hiện

```bash
kubectl exec -n triage-hub <pod> -- curl -s localhost:8080/metrics | grep aiops_triage_requests_total
```

Kiểm tra env `AIOPS_OBSERVABILITY_ENABLED=true`.

---

## 10. Các Cải Tiến Đã Triển Khai & Kế Hoạch

### ✅ Đã triển khai thực tế

- **Overall Error Rate widget**: Math Expression tổng hợp tất cả services
- **Success Rate per Lambda**: `100 - (err/inv * 100)%` per function
- **EventBridge Broadcast**: Jira assignment → `broadcast-notifier` → Slack tự động
- **19 Custom Prometheus Metrics**: LLM cost, circuit breaker, idempotency, budget...
- **OTLP Distributed Tracing**: OpenTelemetry spans qua OTLP endpoint
- **KEDA Auto-scaling**: Worker scale theo `buffer-queue.fifo` depth
- **Cost Monitoring Widget**: `EstimatedCharges` USD trong Dashboard
- **ServiceLens Deep-link**: Shortcut vào CloudWatch Service Map
- **Prometheus EC2 Dynamic IP**: SSM Parameter Store cập nhật IP tự động

### 🔜 Kế hoạch cải tiến

1. **Anomaly Detection**: ML-based CloudWatch Anomaly Detection thay ngưỡng tĩnh
2. **Auto-remediation**: EventBridge + SSM Automation tự restart khi Alarm
3. **Slack Chatbot**: AWS Chatbot gửi Alarm trực tiếp vào Slack channel
4. **Grafana Dashboard**: Visualize custom Prometheus metrics từ AI Engine
