# Security & Compliance - TF1 Triage Hub

Thư mục này chứa tài liệu Security & Compliance cho nền tảng **TF1 - Triage Hub** của nhóm CDO.

## Các file chính

| File | Mục đích |
|---|---|
| `tenant-isolation.md` | Thiết kế cô lập dữ liệu theo tenant cho KAN-218. |
| `encryption.md` | Thiết kế mã hóa dữ liệu at rest và in transit cho KAN-219. |
| `audit-trail.md` | Thiết kế audit trail đầu cuối cho KAN-220. |
| `task-evidence-comments.md` | Nội dung evidence có thể paste vào Jira. |

## Tóm tắt nhiệm vụ

Phần Security & Compliance tập trung vào 3 ý chính:

```text
Tenant Isolation:
Tenant A không được thấy dữ liệu Tenant B.

Encryption:
Dữ liệu lưu trữ phải mã hóa, dữ liệu truyền qua mạng phải dùng HTTPS/TLS.

Audit Trail:
Mọi bước từ alert → AI → Jira → Slack → acknowledge phải được lưu lại để truy vết.
```

## Evidence liên quan

- `docs/03_security_design.md`
- `docs/security-compliance/*.md`
- `docs/08_adrs.md`
- `diagrams/security-compliance.drawio`
- Commit SHA
- Pull Request URL
