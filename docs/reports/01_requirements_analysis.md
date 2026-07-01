# Requirements Analysis - Task force 1 · CDO 09

<!-- Doc owner: Nhóm CDO 09 (Tiến)
     Status: Approved (W12)
     Word target: 800-1500 từ -->

## 1. Đề tài context (Owner: Tiến)

Hệ thống **Triage Hub** được xây dựng nhằm giải quyết bài toán giảm tải cho đội ngũ on-call (gồm 8 engineer) của một SaaS startup B2B (20k active users, ~50 microservices). Hiện tại, đội ngũ này đang gặp tình trạng burnout nặng nề do phải xử lý thủ công hơn 50 alert mỗi tuần, với thời gian trung bình 30-60 phút cho mỗi incident (MTTR tăng cao). 80% công việc của họ mang tính lặp đi lặp lại như: tra cứu log, truy vấn metric từ các hệ thống giám sát, tạo vé Jira thủ công và tìm kiếm/ping người chịu trách nhiệm (team owner).

Triage Hub sẽ tự động hóa luồng tiếp nhận cảnh báo, gom thông tin ngữ cảnh liên quan (logs, metrics, deployment history), dùng AI Engine (Amazon Bedrock LLM) để phân tích tìm nguyên nhân gốc rễ và đề xuất cách xử lý (actionable suggestions), tự tạo ticket Jira và thông báo qua Slack kèm nút Acknowledge 1-click. Engineer chỉ cần kiểm tra lại và thực hiện hành động, loại bỏ hoàn toàn các bước tìm kiếm thủ công ban đầu.

## 2. Infra non-functional requirements (Owner: Tiến)

| NFR                   | Target               | Justification                                                                           |
| --------------------- | -------------------- | --------------------------------------------------------------------------------------- |
| Multi-tenant scale    | ≥ 50 tenants         | Đáp ứng nhu cầu tăng trưởng khách hàng SaaS B2B của startup                             |
| SLO p99 latency       | < 1000ms             | Đảm bảo phản hồi nhanh cho các API tiếp nhận và chuyển tiếp alert                       |
| Availability          | ≥ 99.5%              | Cam kết dịch vụ SLA hoạt động liên tục cho hệ thống trực ca on-call                     |
| Error rate            | < 0.5%               | Hạn chế tối đa việc mất mát tin nhắn cảnh báo để không bỏ lỡ sự cố                      |
| Cost per tenant/month | ~ $20 - $30 / tenant | Ngân sách tối ưu hóa dựa trên việc sử dụng tài nguyên dùng chung và Serverless          |
| Onboarding SLA        | < 1 phút             | Tự động hóa quá trình khởi tạo tenant (Ghi DynamoDB và liên kết API Gateway Usage Plan) |

| Security baseline | IAM least-priv + KMS encryption + Audit Trail 90 ngày | Tuân thủ các tiêu chuẩn bảo mật cho dữ liệu log/metric của khách hàng |

## 3. Differentiation angle (KEY) (Owner: Tiến)

- **Angle chọn**: **Hybrid Architecture (Event-Driven Ingestion + Containerized AI Orchestration)**
- **Why this angle**:
  - **Tối ưu hóa Chi phí & Tải đột biến (Ingestion Phase)**: Sử dụng mô hình Serverless hoàn toàn (API Gateway + AWS Lambda + Amazon SQS) tại cổng tiếp nhận để xử lý các đợt bùng phát cảnh báo (alert spikes) một cách tức thời mà không phải trả phí duy trì server lúc rảnh rỗi.
  - **Độ tin cậy & Cách ly Doanh nghiệp (Processing Phase)**: Sử dụng Amazon EKS để vận hành các pod AI App. Việc này giúp dễ dàng triển khai cách ly đa khách hàng (multi-tenant isolation) ở mức độ compute bằng Kubernetes Namespaces, Resource Quotas, Network Policies, và tận dụng các công cụ giám sát chuẩn doanh nghiệp (Prometheus, Grafana, OpenTelemetry) có sẵn trên K8s. Đồng thời, các pod chạy liên tục giúp loại bỏ hoàn toàn vấn đề trễ khởi động lạnh (cold start latency) của Lambda khi điều phối các tác vụ phân tích AI phức tạp.
- **Trade-off chấp nhận**: Độ phức tạp vận hành (Ops complexity) tăng lên do phải quản trị một cụm K8s (EKS) so với việc triển khai 100% Serverless. Tuy nhiên, đánh đổi này mang lại khả năng quản lý resource và bảo mật cô lập tốt hơn cho mô hình SaaS B2B.
- **Locked T3 W11**: chưa khóa thiết kế.

## 4. Constraints (Owner: Tiến)

- **AWS only**: Toàn bộ hệ thống chạy trên Cloud AWS.
- **Region**: Mặc định chạy tại single-region `us-east-1` theo yêu cầu trực tiếp từ phía CTO của khách hàng.
- **Budget**: Giới hạn tối đa $200 cho toàn bộ tài nguyên thử nghiệm trong 2 tuần capstone.
- **Code freeze**: Thứ 4 Tuần 12 lúc 18h00.

## 5. Open questions (Owner: Tiến)

- [x] **Q1: Tần suất gửi telemetry data từ phía Customer App là bao nhiêu để tính toán tải cho Buffer Queue?**
  - _Giải quyết với nhóm AI & Client:_ Tối đa ~100 alerts/phút trong các tình huống cao điểm, hệ thống SQS hiện tại hoàn toàn đáp ứng được.
- [x] **Q2: AI API Contract yêu cầu đầu ra chi tiết của Schema đề xuất giải pháp như thế nào để map chính xác vào Jira Ticket fields?**
  - _Giải quyết:_ Đã chốt schema output `TriageResponse` chứa các trường `suspected_root_cause`, `recommended_actions` và block `ticket_payload` (bao gồm summary, description, labels) giúp Lambda `notify-dispatcher` map trực tiếp sang Jira API.
