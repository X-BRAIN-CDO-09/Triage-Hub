# 08 - Architecture Decision Records: Security & Compliance

Tài liệu này ghi lại các quyết định kiến trúc quan trọng cho phần Security & Compliance của **TF1 - Triage Hub CDO platform**.

---

## ADR-SEC-001: Dùng tenant_id làm khóa cô lập dữ liệu chính

### Context

Triage Hub xử lý dữ liệu của nhiều tenant. Mỗi alert, AI decision, Jira ticket, Slack activity và audit record đều phải thuộc về một tenant cụ thể. Client yêu cầu context isolation per-tenant và không được leak dữ liệu giữa tenant.

### Decision

Mọi payload bắt buộc phải có `tenant_id`. DynamoDB audit table dùng partition key theo tenant:

```text
PK = TENANT#<tenant_id>
SK = INCIDENT#<incident_id>#EVENT#<timestamp>
```

S3 audit archive cũng dùng prefix theo tenant:

```text
tenant_id=<tenant_id>/year=<yyyy>/month=<mm>/day=<dd>/incident_id=<incident_id>/
```

### Consequence

- Dễ query audit theo tenant.
- Giảm nguy cơ cross-tenant access.
- Dễ chứng minh tenant isolation trong demo.
- Cần validate `tenant_id` nghiêm ngặt ở đầu vào.

### Alternatives

- Dùng một bảng audit chung không partition theo tenant: loại bỏ vì dễ scan/query nhầm dữ liệu.
- Tạo một bảng riêng cho mỗi tenant: loại bỏ vì phức tạp và không cần thiết cho capstone/demo.

---

## ADR-SEC-002: Dùng AWS KMS và Secrets Manager để bảo vệ dữ liệu nhạy cảm

### Context

Triage Hub cần lưu audit record, Jira token, Slack webhook và AI credential. Những dữ liệu này cần được bảo vệ khi lưu trữ và không được hardcode trong source code.

### Decision

Sử dụng:

- AWS KMS/SSE-KMS cho DynamoDB và S3 audit data.
- AWS Secrets Manager hoặc SSM Parameter Store SecureString cho Jira token, Slack webhook và AI credential.
- IAM least privilege để service chỉ đọc được secret cần thiết.

### Consequence

- Secret không bị lộ trong GitHub repo.
- Dễ rotate secret sau này.
- Dễ chứng minh encryption at rest.
- Cần cấu hình IAM/KMS policy đúng để tránh lỗi runtime.

### Alternatives

- Lưu secret trong `.env`: loại bỏ vì dễ bị commit nhầm.
- Hardcode token trong Lambda/code: loại bỏ vì vi phạm security baseline.
- Dùng một secret chung cho mọi integration: loại bỏ vì không đạt least privilege tốt.

---

## ADR-SEC-003: Dùng DynamoDB cho audit query nhanh và S3 cho audit archive dài hạn

### Context

Client yêu cầu audit trail đầy đủ cho mọi AI decision và integration activity. Hệ thống cần query nhanh incident lifecycle trong demo, đồng thời có nơi lưu trữ audit record dài hạn.

### Decision

Dùng hai lớp lưu trữ:

- DynamoDB: lưu audit event để query nhanh theo tenant/incident.
- S3: lưu audit archive dài hạn theo prefix tenant/date/incident.

### Consequence

- DynamoDB phù hợp để demo query lifecycle nhanh.
- S3 phù hợp để lưu archive chi phí thấp.
- Có thể export evidence dễ dàng.
- Cần đảm bảo audit writer ghi đồng bộ hoặc có cơ chế retry khi một lớp lưu trữ lỗi.

### Alternatives

- Chỉ dùng CloudWatch Logs: loại bỏ vì khó query theo tenant/incident và không đủ audit structure.
- Chỉ dùng S3: loại bỏ vì query demo không tiện.
- Chỉ dùng DynamoDB: loại bỏ vì archive dài hạn có thể tốn chi phí hơn S3.

---

## ADR-SEC-004: Bắt buộc dùng HTTPS/TLS cho mọi external integration

### Context

Triage Hub giao tiếp với AI endpoint, Jira API và Slack webhook. Đây là các luồng có thể chứa incident context và thông tin nhạy cảm.

### Decision

Mọi external integration phải dùng HTTPS/TLS:

```text
Alert Source → API Gateway
Lambda → AI Endpoint
Lambda → Jira API
Lambda → Slack Webhook
```

Không dùng HTTP plaintext.

### Consequence

- Bảo vệ dữ liệu khi truyền qua mạng.
- Phù hợp yêu cầu encryption in transit.
- Dễ explain trong security review.
- Cần kiểm tra endpoint URL không dùng `http://`.

### Alternatives

- Cho phép HTTP nội bộ trong demo: loại bỏ vì dễ tạo thói quen sai và khó defend trước mentor.
- Chỉ dùng TLS cho public endpoint: loại bỏ vì Jira/Slack/AI cũng cần bảo vệ data in transit.

---

## ADR-SEC-005: AI chỉ diagnose/suggest, không auto-remediation

### Context

Client đã chốt hard requirement: Triage Hub không được auto-remediation. AI chỉ được chẩn đoán nguyên nhân và đề xuất bước xử lý. Engineer vẫn là người confirm và hành động.

### Decision

Security design enforce human-in-the-loop:

- AI response chỉ gồm diagnosis, confidence score và recommended action.
- Không cấp quyền cho AI/service gọi lệnh sửa production resource.
- Jira/Slack chỉ tạo ticket/thông báo/acknowledge.

### Consequence

- Giảm rủi ro AI gây thay đổi production ngoài ý muốn.
- Phù hợp scope client.
- Dễ defend khi mentor hỏi hard NEVER boundary.
- MTTR giảm nhờ hỗ trợ context/diagnosis, không phải nhờ auto-fix.

### Alternatives

- Cho phép AI chạy script remediation: loại bỏ vì ngoài scope và rủi ro cao.
- Cho phép auto-close ticket: loại bỏ vì có thể che giấu incident thật.
