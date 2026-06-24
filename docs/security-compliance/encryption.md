# Thiết kế Encryption cho Data at Rest và Data in Transit

## 1. Mục tiêu

Tài liệu này mô tả cách nền tảng **Triage Hub** bảo vệ dữ liệu bằng mã hóa khi lưu trữ và khi truyền qua mạng.

Task liên quan:

```text
KAN-219 - Implement Encryption for Data at Rest and In Transit
```

## 2. Khái niệm cần hiểu

### Data at rest

Là dữ liệu đang được lưu trong AWS service, ví dụ:

- audit record trong DynamoDB;
- audit archive trong S3;
- token Jira/Slack trong Secrets Manager;
- log trong CloudWatch Logs;
- container image trong ECR.

### Data in transit

Là dữ liệu đang truyền qua mạng, ví dụ:

- alert source gọi API Gateway;
- Lambda gọi AI endpoint;
- Lambda gọi Jira API;
- Lambda gọi Slack webhook.

## 3. Encryption at rest

| Thành phần | Dữ liệu lưu | Cơ chế bảo vệ |
|---|---|---|
| DynamoDB Audit Table | AI decision, incident history, Jira/Slack activity | KMS encryption. |
| S3 Audit Archive | Audit record dài hạn | SSE-KMS. |
| Secrets Manager | Jira token, Slack webhook, AI credential | KMS-managed encryption. |
| SSM Parameter Store | Config/secret nếu dùng SSM | SecureString + KMS. |
| CloudWatch Logs | Runtime logs | Log group encryption + retention policy. |
| ECR | Container image | ECR encryption + vulnerability scanning. |

## 4. Encryption in transit

| Luồng | Yêu cầu |
|---|---|
| Alert Source → API Gateway | HTTPS/TLS. |
| API Gateway → Lambda | AWS managed secure service integration. |
| Lambda → AI Engine | HTTPS/TLS hoặc private endpoint có TLS. |
| Lambda → Jira API | HTTPS/TLS. |
| Lambda → Slack Webhook | HTTPS/TLS. |
| GitHub Actions → AWS | HTTPS/TLS + OIDC/IAM role nếu có. |

Không được dùng HTTP plaintext cho endpoint bên ngoài.

## 5. Secrets management

Các secret không được hardcode trong source code, file `.env`, README hoặc commit GitHub.

Danh sách secret cần bảo vệ:

```text
JIRA_API_TOKEN
JIRA_BASE_URL
SLACK_WEBHOOK_URL
AI_SERVICE_API_KEY
AI_ENDPOINT_URL nếu endpoint private/sensitive
AWS credentials nếu có dùng local demo
```

Cách lưu:

```text
AWS Secrets Manager
hoặc
AWS Systems Manager Parameter Store - SecureString
```

Ví dụ naming convention:

```text
/triage-hub/dev/jira/api-token
/triage-hub/dev/slack/webhook-url
/triage-hub/dev/ai/api-key
```

## 6. KMS key design

Có thể dùng một KMS key riêng cho Triage Hub demo:

```text
alias/triage-hub-demo-kms
```

Key này dùng cho:

- DynamoDB audit table;
- S3 audit bucket;
- Secrets Manager secrets;
- CloudWatch Logs nếu cấu hình.

Quyền sử dụng KMS phải giới hạn theo IAM role cần thiết. Không cấp wildcard quá rộng như `kms:*` cho tất cả service.

## 7. IAM least privilege cho encryption

Ví dụ policy ở mức thiết kế:

```text
Jira Connector Lambda:
- secretsmanager:GetSecretValue chỉ với Jira secret
- kms:Decrypt chỉ với KMS key liên quan

Slack Connector Lambda:
- secretsmanager:GetSecretValue chỉ với Slack secret
- kms:Decrypt chỉ với KMS key liên quan

Audit Writer Lambda:
- dynamodb:PutItem vào audit table
- s3:PutObject vào audit bucket/prefix
- kms:Encrypt/kms:Decrypt theo nhu cầu
```

## 8. Kiểm soát không leak secret

Cần áp dụng:

- `.gitignore` cho file `.env`, credential, local config;
- không paste token vào Jira comment công khai;
- không đưa token thật vào screenshot evidence;
- dùng placeholder trong tài liệu:

```text
<SLACK_WEBHOOK_URL>
<JIRA_API_TOKEN>
<AI_SERVICE_API_KEY>
```

## 9. Test cases

| ID | Test case | Kết quả mong muốn |
|---|---|---|
| ENC-01 | Kiểm tra DynamoDB audit table | Encryption enabled. |
| ENC-02 | Kiểm tra S3 audit bucket | SSE-KMS enabled. |
| ENC-03 | Kiểm tra secret storage | Token nằm trong Secrets Manager/SSM, không nằm trong repo. |
| ENC-04 | Gọi API Gateway | Dùng HTTPS. |
| ENC-05 | Gọi AI/Jira/Slack | Dùng HTTPS/TLS. |
| ENC-06 | Scan repo | Không có secret thật bị commit. |

## 10. Acceptance Criteria

Điều kiện hoàn thành:

- Dữ liệu lưu trữ quan trọng được mã hóa bằng KMS/SSE-KMS/service encryption.
- Dữ liệu truyền qua mạng dùng HTTPS/TLS.
- Secret không hardcode và không commit lên GitHub.
- Có documentation và diagram chứng minh encryption flow.
- Có ADR ghi lại quyết định dùng KMS/Secrets Manager/TLS.
