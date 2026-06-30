# Tổng Quan Hệ Thống Observability & Hướng Dẫn Kiểm Tra

Tài liệu này tổng hợp toàn bộ kiến trúc Observability đã được triển khai cho dự án Triage-Hub, giải thích ý nghĩa của từng chỉ số (metric) đang được giám sát, và cung cấp hướng dẫn chi tiết từng bước để kiểm tra việc luân chuyển dữ liệu từ hệ thống lên CloudWatch và SNS.

---

## 1. Tổng Quan Kiến Trúc Observability

Hệ thống Observability bao gồm 4 thành phần chính:
1. **CloudWatch Dashboard**: Bảng điều khiển tập trung chứa các biểu đồ trực quan (Widgets) cho toàn bộ thành phần hệ thống (API Gateway, Lambda, SQS, DynamoDB, EKS).
2. **CloudWatch Metric Alarms**: Hệ thống cảnh báo tự động khi các chỉ số vượt qua ngưỡng an toàn.
3. **AWS SNS (Simple Notification Service)**: Kênh phát tín hiệu cảnh báo (Email, SMS) cho đội ngũ vận hành.
4. **CloudWatch Logs Insights & Container Insights**: Thu thập và phân tích Logs nâng cao cho Lambda và các Metrics chuyên sâu cho EKS (Kubernetes).

---

## 2. Giải Thích Các Chỉ Số (Metrics) Và Trường Dữ Liệu

### A. Amazon API Gateway
*Điểm vào (Entry point) của toàn bộ request từ người dùng.*
- **Count**: Tổng số lượng request gửi đến API. Giúp đánh giá lưu lượng truy cập.
- **Latency**: Thời gian trung bình (mili-giây) từ lúc API Gateway nhận request cho đến khi trả về response.
- **4XXError**: Số lượng lỗi do phía Client (ví dụ: Bad Request 400, Unauthorized 401). Thường do dữ liệu đầu vào sai.
- **5XXError**: Số lượng lỗi do phía Server (ví dụ: Internal Server Error 500). Đây là chỉ số quan trọng cần được báo động ngay lập tức vì hệ thống backend đang gặp sự cố.

### B. AWS Lambda (Functions)
*Xử lý logic cốt lõi (Alert Ingest, Jira Dispatcher, Notify Dispatcher).*
- **Invocations**: Số lần hàm Lambda được gọi.
- **Duration**: Thời gian thực thi của hàm. Nếu Duration chạm ngưỡng timeout của Lambda, quá trình xử lý sẽ thất bại.
- **Errors**: Số lần hàm Lambda ném ra Exception chưa được xử lý hoặc bị crash.
- **Throttles**: Số lượng request bị từ chối do vượt quá giới hạn thực thi đồng thời (Concurrency Limit) của Lambda. 

### C. Amazon SQS (Queues)
*Hàng đợi đệm (Buffer) và điều phối.*
- **ApproximateNumberOfMessagesVisible (Queue Depth)**: Số lượng tin nhắn đang chờ trong hàng đợi để được xử lý. Nếu số này tăng đột biến, chứng tỏ Consumer (Lambda) xử lý không kịp hoặc đang bị lỗi.
- **ApproximateAgeOfOldestMessage**: Tuổi của tin nhắn cũ nhất (tính bằng giây). Chỉ số này rất quan trọng để đảm bảo SLA: nếu tin nhắn nằm trong queue quá lâu (ví dụ > 3600 giây), nghĩa là hệ thống đang ứ đọng nghiêm trọng.

### D. Amazon DynamoDB
*Cơ sở dữ liệu lưu trạng thái.*
- **ThrottledRequests / ConsumedCapacity**: Số lượng yêu cầu đọc/ghi bị từ chối do vượt quá dung lượng quy định (Provisioned Capacity). Nếu tăng cao, cần cấu hình Auto Scaling cho DB.
- **SystemErrors**: Lỗi phát sinh từ nội bộ hạ tầng AWS DynamoDB (rất hiếm gặp, nhưng nghiêm trọng nếu có).

### E. Application Load Balancer (Internal ALB)
*Cổng giao tiếp nội bộ định tuyến traffic cho AI Engine.*
- **RequestCount**: Tổng số lượng request gửi đến ALB.
- **HTTPCode_Target_5XX_Count**: Số lượng lỗi 5XX trả về từ các Pod (Target). Phản ánh việc AI Engine (FastAPI/Worker) bị lỗi.
- **HTTPCode_ELB_5XX_Count**: Số lượng lỗi 5XX do chính ALB sinh ra (ví dụ không tìm thấy target khả dụng).
- **TargetResponseTime**: Thời gian xử lý trung bình (độ trễ) của AI Engine.

### F. Amazon EC2 (Customer App)
*Máy chủ giả lập ứng dụng của khách hàng gửi luồng cảnh báo.*
- **CPUUtilization**: Phần trăm sử dụng CPU. Nếu tăng cao trên mức quy định (ví dụ 80%) sẽ kích hoạt Alarm cảnh báo quá tải.
- **NetworkIn / NetworkOut**: Lưu lượng mạng vào và ra khỏi máy chủ EC2.

### G. Amazon S3 (Artifacts Storage)
*Lưu trữ log và số liệu thô phục vụ audit.*
- **BucketSizeBytes**: Tổng dung lượng lưu trữ (được AWS đo và cập nhật mỗi ngày một lần).
- **NumberOfObjects**: Tổng số lượng file đang được lưu trong bucket.

### H. CloudWatch Logs Insights (Phân tích Log)
Các widget dạng log-insight trên Dashboard sử dụng các query có các trường:
- `@timestamp`: Thời điểm sinh ra log.
- `@message`: Nội dung gốc của log. Dùng hàm `filter @message like /Error/` để tìm các dòng log lỗi.
- `@duration`, `@billedDuration`: Thời gian chạy thực tế và thời gian bị tính phí của Lambda.

---

## 3. Chi Tiết Triển Khai: Logs, Metrics, và Traces (The 3 Pillars of Observability)

Hệ thống được thiết kế bao phủ toàn diện 3 trụ cột (Pillars) của Observability:

### A. Logs (Nhật ký hệ thống)
*Mục đích: Cung cấp bản ghi chi tiết các sự kiện (events) với context cụ thể để debug lỗi.*
- **API Gateway**: Đã được cấp quyền IAM (`AmazonAPIGatewayPushToCloudWatchLogs`) thông qua Account Settings để tự động đẩy Execution Logs và Access Logs về CloudWatch Logs, giúp truy vết lỗi API.
- **AWS Lambda**: Tất cả log từ stdout/stderr của code (ví dụ `console.log`, `logger.error()`) được tự động gom về Log Group `/aws/lambda/<tên-hàm>`. Các widget Logs Insights trên Dashboard sẽ tự động query các group này.
- **Amazon EKS**: Sử dụng add-on `amazon-cloudwatch-observability` đi kèm với IRSA Role để thu thập log từ tất cả các Container/Pod trong cluster, giúp centralized log management (Quản lý log tập trung) về CloudWatch.

### B. Metrics (Chỉ số đo lường)
*Mục đích: Biểu diễn trạng thái sức khỏe của hệ thống dạng chuỗi thời gian (time-series) giúp phát hiện xu hướng và cấu hình cảnh báo (Alarms).*
- **Standard AWS Metrics**: Các dịch vụ Managed (API Gateway, Lambda, SQS, DynamoDB) tự động phát sinh các built-in metrics (như `5XXError`, `Duration`, `QueueDepth`) với độ phân giải 1 phút mà không cần cài đặt thêm agent.
- **Container Insights (EKS)**: EKS Add-on thu thập Metrics chuyên sâu cho tầng hạ tầng và ứng dụng chạy trong Pods (CPU, Memory, Network I/O, Pod Restart Count) và hiển thị trực quan.
- **Metric Alarms**: Sử dụng `aws_cloudwatch_metric_alarm` kết hợp với ngưỡng (Threshold) có thể cấu hình linh hoạt qua file Terraform variables để giám sát các Metric này liên tục.

### C. Traces (Truy vết phân tán - Distributed Tracing)
*Mục đích: Theo dõi hành trình của một request đi xuyên qua nhiều Microservices/Components (API Gateway -> Lambda -> SQS) để tìm ra điểm thắt cổ chai (bottleneck) về hiệu năng.*
- **AWS X-Ray Daemon**: Tích hợp sẵn trong EKS Add-on `amazon-cloudwatch-observability` thông qua policy `AWSXRayDaemonWriteAccess` ở tầng IRSA Role.
- Các service trong EKS và Lambda có thể sinh ra Trace Segments. Trên AWS Console, tính năng X-Ray Service Map sẽ tự động vẽ ra bản đồ tương tác giữa các dịch vụ.

---

## 4. Hướng Dẫn Từng Bước Kiểm Tra & Xác Thực Dữ Liệu
Để đảm bảo hệ thống Observability hoạt động, hãy thực hiện lần lượt các bước sau:

### Bước 1: Xác nhận đăng ký SNS (Subscription)
1. Sau khi chạy lệnh `terraform apply`, AWS SNS sẽ gửi một email xác nhận đến địa chỉ email đã cấu hình (`nhatphanhk102@gmail.com`).
2. Mở email có tiêu đề **AWS Notifications - Subscription Confirmation**.
3. Nhấp vào đường link **Confirm subscription**.
4. AWS sẽ mở một trang web hiển thị "Subscription confirmed!". Lúc này, kênh cảnh báo mới chính thức hoạt động.

### Bước 2: Kiểm tra CloudWatch Dashboard có lên dữ liệu không
1. Đăng nhập vào **AWS Management Console**.
2. Tìm kiếm và mở dịch vụ **CloudWatch**.
3. Ở thanh menu bên trái, chọn **Dashboards**.
4. Chọn Dashboard có tên **triage-hub-dashboard-sandbox**.
5. Nhìn vào các biểu đồ (Widgets):
   - Nếu bạn thấy đường biểu diễn nằm ngang hoặc lấm tấm điểm, tức là Metrics đang được thu thập bình thường.
   - Chú ý phần **Logs Insights** ở cuối Dashboard, nếu có log lỗi sẽ hiện ra dưới dạng bảng.

### Bước 3: Kiểm tra thử nghiệm luồng Cảnh báo (Test Alarm via CLI)
Đây là cách an toàn và nhanh nhất để chắc chắn rằng Email/SMS sẽ được gửi khi hệ thống xảy ra sự cố mà không cần phải chủ động làm hỏng hệ thống:

Mở Terminal / CloudShell đã cài AWS CLI và chạy lệnh ép Alarm sang trạng thái `ALARM`:
```bash
aws cloudwatch set-alarm-state \
    --alarm-name "triage-hub-apigw-5xx-high" \
    --state-value ALARM \
    --state-reason "Kiểm tra hệ thống gửi Email Alert" \
    --region us-east-1
```
*Bạn sẽ nhận được 1 email cảnh báo lập tức (trong vòng 10 giây). Nội dung email sẽ hiển thị thông báo rằng chỉ số 5XX của API Gateway đang bị vượt ngưỡng.*

Sau khi nhận email, hãy đưa Alarm trở lại trạng thái `OK`:
```bash
aws cloudwatch set-alarm-state \
    --alarm-name "triage-hub-apigw-5xx-high" \
    --state-value OK \
    --state-reason "Đã hoàn thành bài test" \
    --region us-east-1
```

### Bước 4: Kiểm tra bằng dữ liệu thực tế (End-to-End)
Nếu bạn muốn hệ thống tự động sinh dữ liệu thực sự (Real Traffic):

1. **Test lỗi 5XX / Lambda Error:**
   - Dùng công cụ `Postman` hoặc `curl` bắn các payload sai định dạng liên tục (spam) vào endpoint API Gateway của hệ thống.
   - Nếu mã code Lambda không catch lỗi này, Lambda sẽ báo `Error` và API Gateway trả về HTTP 500 (5XXError).
   - Đợi khoảng 2-3 phút, CloudWatch sẽ gom đủ số liệu và tự động kích hoạt Alarm, đồng thời gửi email.

2. **Test SQS Queue Depth:**
   - Dùng script Python/NodeJS tạo một vòng lặp gửi 2,000 tin nhắn (messages) liên tục vào `triage-hub-buffer-queue`.
   - Cùng lúc đó, tạm thời `Disable` trigger của Lambda đang xử lý queue này trên AWS Console.
   - Khoảng 1 phút sau, trên Dashboard sẽ thấy chỉ số `ApproximateNumberOfMessagesVisible` vọt lên 2,000.
   - Alarm `triage-hub-buffer-queue-queue-depth-high` sẽ đỏ (In ALARM) vì vượt mức 1000. Gửi Email thông báo tắc nghẽn.
   - Sau đó `Enable` lại Lambda trigger để nó dọn sạch Queue, hệ thống tự động xanh (OK) trở lại.

3. **Test AWS X-Ray Traces:**
   - Thực hiện một luồng (flow) hoàn chỉnh trên ứng dụng (ví dụ: gửi một HTTP request tới API Gateway, request này kích hoạt Lambda, Lambda đẩy dữ liệu vào SQS hoặc DynamoDB).
   - Truy cập **AWS Console > CloudWatch > X-Ray traces > Service map**.
   - Tại đây, bạn sẽ thấy bản đồ dịch vụ (Service map) tự động vẽ ra kiến trúc dựa trên dữ liệu thực tế (các node như API Gateway, Lambda, SQS).
   - Truy cập **Traces** (trong mục X-Ray), lọc các request gần đây để xem timeline chi tiết (Trace segments). Bạn có thể click vào từng segment để xem chính xác hàm Lambda mất bao nhiêu mili-giây, hoặc việc gọi DynamoDB có bị chậm hay không.

4. **Test EC2 CPU Alarm:**
   - Đăng nhập (SSH) hoặc dùng Session Manager để vào máy chủ EC2 của `customer-app`.
   - Chạy lệnh stress-test (ví dụ: `yes > /dev/null &` chạy nhiều lần) để ép CPU hoạt động hết công suất 100%.
   - Chờ khoảng 2 phút, Alarm `<project_name>-ec2-cpu-high` sẽ đỏ (ALARM) và gửi cảnh báo qua Email/SMS. Nhớ tắt tiến trình (`killall yes`) sau khi test xong để Alarm tự động phục hồi về xanh (OK).
---

## 5. Các Kịch Bản Test (Test Cases) Thực Hành Đảm Bảo Có Dữ Liệu

Dưới đây là các bài test cụ thể bạn có thể chạy bằng dòng lệnh (Terminal/PowerShell) để sinh ra dữ liệu thật, từ đó xác minh Logs, Metrics và Traces đều đang hoạt động. 
*Lưu ý: Thay thế `<API_URL>` bằng URL thực tế của API Gateway từ output `apigw_invoke_url`.*

### Test Case 1: Đảm bảo Metrics có dữ liệu (API Gateway & Lambda)
**Mục tiêu**: Tạo ra lượng truy cập cơ bản (Traffic) để kích hoạt Metrics.
**Hành động**: Bắn 10 request hợp lệ liên tục tới API Gateway.
**Lệnh (Bash/PowerShell)**:
```bash
for i in {1..10}; do curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" <API_URL>/alerts; done
```
**Xác minh**:
1. Truy cập **CloudWatch > Dashboards > triage-hub-dashboard-sandbox**.
2. Tại Widget "API Requests" (Count), bạn sẽ thấy số lượng tăng thêm 10.
3. Tại Widget "Lambda Invocations", hàm `alert-ingest` sẽ tăng thêm 10 lần gọi.

### Test Case 2: Đảm bảo Logs có dữ liệu và ghi nhận lỗi (Logs Insights)
**Mục tiêu**: Kích hoạt Log Execution và ép hệ thống ghi log lỗi (Error Log).
**Hành động**: Gửi một request với payload hoàn toàn sai định dạng để Lambda/API Gateway bắt lỗi.
**Lệnh**:
```bash
curl -X POST <API_URL>/alerts \
     -H "Content-Type: application/json" \
     -d '{"invalid_field": "test_log", "missing_required_data": true}'
```
**Xác minh**:
1. Truy cập **CloudWatch > Logs Insights**.
2. Chọn Log Group: `/aws/lambda/triage-hub-alert-ingest`.
3. Chạy Query sau:
   ```text
   fields @timestamp, @message
   | filter @message like /Error|Exception|invalid/
   | sort @timestamp desc
   | limit 20
   ```
4. Bạn phải thấy dòng log báo lỗi tương ứng với payload sai vừa gửi. Nếu có log, tức là luồng CloudWatch Logs đang hoạt động hoàn hảo.

### Test Case 3: Đảm bảo Traces có dữ liệu kết nối (X-Ray)
**Mục tiêu**: Đảm bảo AWS X-Ray kết nối được các dịch vụ (API -> Lambda -> SQS) thành một chuỗi (Trace).
**Hành động**: Gửi 1 request thành công để toàn bộ chuỗi được kích hoạt.
**Lệnh**:
```bash
curl -X POST <API_URL>/alerts \
     -H "Content-Type: application/json" \
     -d '{"alert_id": "TEST-001", "severity": "high", "message": "Testing X-Ray traces"}'
```
**Xác minh**:
1. Truy cập **CloudWatch > X-Ray traces > Service map**.
2. Đợi 1-2 phút, màn hình sẽ vẽ ra sơ đồ luồng đi của dữ liệu: `Client` vạch đường nối tới `API Gateway`, nối tiếp tới `AWS::Lambda`, và nối tiếp tới `AWS::SQS` (buffer-queue).
3. Chuyển sang tab **Traces**, click vào một Trace ID mới nhất. Bạn sẽ thấy biểu đồ Gantt (timeline) phân rã từng mili-giây:
   - Bao nhiêu mili-giây tốn cho việc API Gateway routing?
   - Bao nhiêu mili-giây tốn cho Lambda execution (cold start hay warm start)?
   - Tốc độ Lambda đẩy data vào SQS là bao nhiêu?
Nếu sơ đồ này hiển thị đầy đủ các Node, hệ thống Traces đã hoạt động chính xác.

### Test Case 4: Đảm bảo Container Insights thu thập Metrics (EKS)
**Mục tiêu**: Đảm bảo Add-on CloudWatch Observability trong EKS đang bơm dữ liệu về.
**Hành động**: Cập nhật hoặc scale số lượng Pod trong EKS (nếu có ứng dụng đang chạy).
**Lệnh**:
```bash
kubectl scale deployment/customer-app --replicas=3 -n default
```
**Xác minh**:
1. Truy cập **CloudWatch > Insights > Container Insights**.
2. Chọn Cluster `triage-hub-eks-sandbox`.
3. Nhìn vào biểu đồ **Pod Count**, bạn sẽ thấy số lượng Pod tăng lên. Các chỉ số CPU và Memory Utilization của EKS Node sẽ hiển thị dữ liệu dao động realtime.
