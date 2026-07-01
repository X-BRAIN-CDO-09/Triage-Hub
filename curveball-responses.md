# Triage-Hub CDO09 - Curveball Responses

**Mục đích:** Mô phỏng real-world client change request. Tập phản xạ adapt scope thay đổi mà không panic, không cãi cọ, không miss deadline. 
**Yêu cầu:** Mỗi lần xử lý curveball xong, team cần document response (cách giải quyết, đánh giá impact, action items) vào file này. Buổi chấm panel sẽ dựa vào đây để chất vấn cách team xử lý tình huống.

---

## #1: Mức độ Nhẹ (Timeline: W11 T5 cuối, 15p)

**Ví dụ Scenario:** "Client thêm severity classify low/med/high, contract sửa gì?" 

### Team Response
> *Document cách giải quyết nhanh, những thay đổi cần thiết, và đánh giá tác động.*

- **Scenario thực tế nhận được:** Client yêu cầu thêm field `severity` với các giá trị `low`, `medium`, `high`, `critical` vào payload gửi tới `/alerts` API.
- **Đánh giá Impact:** 
  - **API Contract:** Thay đổi schema của request.
  - **Lambda `alert-ingest`:** Cần thêm logic validation cho field mới.
  - **SQS `buffer-queue`:** Payload chuyển qua queue sẽ lớn hơn một chút nhưng không ảnh hưởng performance.
  - **EKS (`tf1-api` / `tf1-worker`):** Cần parse field `severity` và lưu vào DynamoDB. AI Engine có thể dùng thông tin này làm feature đầu vào.
  - **Lambda `notify-dispatcher`:** Có thể format tin nhắn Slack theo màu (Đỏ cho critical, Vàng cho medium) hoặc mention `@channel` nếu là critical.
- **Action Plan & Hướng xử lý:** 
  1. Cập nhật tài liệu API Contract (VD: Swagger/OpenAPI) cho `/alerts`.
  2. Sửa code `alert-ingest` Lambda: Thêm validation (vd: zod/joi), nếu client không truyền thì default là `medium` để đảm bảo backward compatibility.
  3. Cập nhật code Go/Python trong EKS pods để map field này vào Model và DynamoDB schema.
  4. Sửa code `notify-dispatcher` Lambda thêm switch-case theo `severity` để đổi icon/color Slack message.
- **Kết quả / Link Artifacts:** [Update API Docs](#) | [PR Lambda Ingest](#) | [PR Notify Dispatcher](#)

---

## #2: Mức độ Medium (Timeline: W12 T2 chiều, 30p)

**Ví dụ Scenario:** "Traffic tăng 5x vào tuần tới, scale ra sao?"

### Team Response
> *Document chiến lược xử lý, đặc biệt chú ý tới vấn đề zero-downtime migration hoặc auto-scaling plan.*

- **Scenario thực tế nhận được:** Dự kiến event lớn, lượng alert đổ về hệ thống tăng 5 lần so với bình thường.
- **Đánh giá Impact:** 
  - **API Gateway & `alert-ingest`:** Tự động scale nhưng có nguy cơ chạm limit concurrent executions của Lambda (mặc định 1000/region).
  - **SQS `buffer-queue`:** Hoạt động tốt như một "shock absorber" (bộ đệm giảm xóc).
  - **Lambda `push-to-ai`:** Scale theo SQS batch nhưng nếu đẩy quá nhanh có thể làm sập EKS Internal ALB hoặc Pods.
  - **EKS Pods & Nodes:** Cần scale out để đáp ứng lượng request khổng lồ từ `push-to-ai`.
  - **DynamoDB:** Có thể bị throttle (ProvisionedThroughputExceededException) nếu WCU/RCU không đủ.
- **Action Plan & Hướng xử lý:** 
  1. **Kiểm soát luồng (Rate Limiting):** Đặt Reserved Concurrency Limit cho Lambda `push-to-ai` để giới hạn số lượng request đồng thời đánh vào EKS ALB, tránh EKS bị quá tải.
  2. **EKS Scaling:** 
     - Kiểm tra và tăng Max Capacity cho EKS Node Group (Auto Scaling Group) trong Terraform.
     - Cấu hình HPA (Horizontal Pod Autoscaler) cho `tf1-api` và `tf1-worker` scale theo metric CPU/Memory hoặc lý tưởng nhất là scale theo độ dài của SQS queue (KEDA).
  3. **DynamoDB:** Chuyển sang chế độ **On-Demand** (Pay-per-request) tạm thời trong tuần event để tránh bị giới hạn Read/Write Capacity, hoặc tăng Provisioned limits và Auto Scaling target.
  4. Kiểm tra Soft Limits của AWS (như Lambda Concurrency) và tạo support ticket nâng limit nếu cần.
- **Kết quả / Link Artifacts:** [Terraform HPA Config PR](#) | [DynamoDB On-Demand PR](#)

---

## #3: Mức độ Chaos (Timeline: W12 T4 chiều, 60p)

**Ví dụ Scenario:** "Region down 30 phút, failover thế nào?" 

### Team Response
> *Document cách xử lý sự cố diện rộng, đảm bảo HA (High Availability) và fault tolerance.*

- **Scenario thực tế nhận được:** Primary Region (VD: `ap-southeast-1`) bị sập toàn bộ dịch vụ do sự cố từ AWS.
- **Đánh giá Impact:** Toàn bộ hệ thống Triage-Hub ngừng hoạt động. Khách hàng không gửi được alert, SLA bị vi phạm.
- **Action Plan & Hướng xử lý (Chiến lược Active-Passive DR):** 
  Do kiến trúc hiện tại nằm ở 1 region, ta cần thiết kế phương án Multi-Region Disaster Recovery (RTO < 15p, RPO < 5p):
  1. **Replication Dữ liệu:**
     - **DynamoDB:** Kích hoạt Global Tables, sync dữ liệu sang Secondary Region (VD: `ap-northeast-1`).
     - **S3:** Kích hoạt tính năng Cross-Region Replication (CRR) cho artifact bucket.
     - **Secrets Manager:** Sử dụng tính năng Replicate secret to other regions.
  2. **Infrastructure:**
     - Chạy sẵn (Pilot Light) hoặc dùng Terraform deploy nhanh (Warm Standby) toàn bộ EKS Cluster, ALB, API Gateway, SQS và Lambdas ở Secondary Region.
  3. **Routing & Failover (Route53):**
     - Thiết lập DNS Record trên Route 53 bằng chính sách Failover Routing.
     - Tạo Route 53 Health Checks giám sát API Gateway (Primary Region). Nếu fail liên tục, DNS tự động trỏ traffic sang API Gateway ở Secondary Region.
  4. *Lưu ý với SQS:* SQS không replicate giữa các region. Các message đang nằm trong queue ở Primary Region sẽ bị kẹt cho đến khi region khôi phục. Các alert mới từ client sẽ tự động flow vào SQS ở Secondary Region.
- **Kết quả / Link Artifacts:** [Disaster Recovery Architecture Diagram](#) | [Terraform Global Tables Config](#)
