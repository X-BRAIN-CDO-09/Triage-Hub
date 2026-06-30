# Verification Report — CDO Triage Hub

**Ngày:** 2026-07-01
**Người thực hiện:** CDO (Claude assist)
**Nhánh:** `feature/ai-engine`
**Phạm vi:** Verify toàn bộ code/test/logic phần CDO sau khi fix Issue #1 + #2. AI engine chỉ verify (không sửa theo ràng buộc).

---

## 1. Tổng kết trạng thái

| Hạng mục | Kết quả |
|---|---|
| AI engine — ruff lint + format | ✅ PASS (20 files) |
| AI engine — bandit (-ll) | ✅ PASS (0 issue) |
| AI engine — pytest | ✅ **70/70 PASS** |
| Lambda alert-ingest — Jest | ✅ **10/10 PASS** (sau khi viết lại) |
| Resolver — ruff + bandit + compile | ✅ PASS (sau fix) |
| Lambda JS — node --check (4 file) | ✅ PASS |
| CI workflows — YAML (5 file) | ✅ PASS |
| Terraform — fmt + validate | ✅ PASS |

Tất cả test/lint đều xanh sau các fix bên dưới.

---

## 2. Lỗi phát hiện & đã sửa (best practice)

### 2.1 `tests/local` — bộ test lambda hỏng hoàn toàn
- **BOM (Byte Order Mark)** ở đầu `package.json` + 2 file `.js` → jest không parse được config (`Unexpected token '﻿'`). **Đã strip BOM** cả 3 file.
- **`test_lambda_push_to_ai.js`** test lambda `push-to-ai` **không tồn tại** trong repo (app/ chỉ có ai-engine, alert-ingest, broadcast-notifier, jira-dispatcher, notify-dispatcher). Dead test → **đã xoá**.
- **`test_lambda_alert_ingest.js`** viết cho contract CŨ (kỳ vọng `status:"Accepted"` + `message_id`, validate tenant trả 400). Handler hiện tại dùng **DynamoDB tenant gating**, trả `{status:"Processed", accepted, dropped}`, check config trước (thiếu `DYNAMODB_TABLE` → 500). **Đã viết lại** khớp contract thật: mock cả DynamoDB + SQS, test config guard / body parsing / tenant gating / happy path FIFO.
- **Pattern test sai:** handler đọc env (`QUEUE_URL`, `DYNAMODB_TABLE`) lúc **module-load**, nhưng test require handler ở top-level trước `beforeEach` → config undefined → luôn 500. **Đã sửa** bằng `loadHandler()` dùng `jest.isolateModules` (require lại sau khi set env).
- **Module resolution:** handler nằm ngoài `rootDir` nên node không thấy `tests/local/node_modules`. **Đã thêm** `modulePaths` vào jest config.
- Dọn dep: bỏ `@aws-sdk/client-secrets-manager` (không còn dùng), thêm `@aws-sdk/client-dynamodb`.

### 2.2 `scripts/assignee_resolver/resolve_assignees.py` — CDO ops tool
- Bỏ **unused import** `collections.defaultdict` (ruff).
- **Hardening bandit B310:** ép scheme `https://` trước `urllib.request.urlopen` để chặn `file://`/`http://` vô tình (`base_url` từ Secrets Manager). Thêm `# nosec B310` có chú thích.

### 2.3 `.gitignore` — best practice + bảo mật
- Thêm `node_modules/`, `.venv/`, `venv/`.
- Thêm pattern chặn secret dumps: `secrets_backup.json`, `secrets*.json`, `*secret*.json`.

### 2.4 `jira-dispatcher/index.js` (đã fix ở phiên trước, ghi lại để đủ)
- Null-safety cho `response` trong `assignJiraTicket` + `updateSlackMessage` (`fetchWithRetry` có thể trả null).

---

## 3. ⚠️ CẢNH BÁO BẢO MẬT — CẦN BẠN XỬ LÝ

**File `secrets_backup.json` ở root repo chứa TOKEN LIVE dạng plaintext:**
- `triage-hub-slack_bot_token-sandbox`
- `triage-hub-jira_api_token-sandbox`
- `triage-hub-slack_signing_secret-sandbox`
- `triage-hub-service_auth_token-sandbox`

**Tôi KHÔNG tạo file này và KHÔNG commit nó.** Đã thêm vào `.gitignore` để chặn commit nhầm.

**Việc bạn cần làm:**
1. Xoá file sau khi dùng xong: file token plaintext trên đĩa là rủi ro.
2. Kiểm tra file **chưa từng bị commit** ở commit cũ nào (nếu lỡ commit → phải rotate token + xoá khỏi history).
3. Nếu nghi đã lộ → **rotate** Slack bot token + Jira API token.

---

## 4. Vấn đề CÒN TỒN ĐỌNG (không thuộc code — cần quyết định)

### Issue #1 (Suggest) — engine mới chưa rollout được
- Root cause: **Security group EC2 Prometheus (`sg-0b38a333cb7c82fd5`) thiếu inbound port 9090** → canary analysis query Prometheus timeout → rollout abort → pod vẫn chạy engine cũ `4e2e5ee` (đọc JSON, không đọc DynamoDB).
- Đây là **hạ tầng observability dùng chung**, có nhánh teammate `feature/Observability_cloudwatch`. Đã dừng chờ bạn chọn hướng fix (qua terraform):
  - **A:** Cho analysis query qua proxy 9000 sẵn có + thêm NAT EIP vào allowlist (giữ security model).
  - **B:** Mở 9090 từ EKS qua VPC peering (private IP), thêm ingress trong terraform.
- Dữ liệu DynamoDB đã đúng (đã fix record `checkout-api` từ email → Jira accountId hợp lệ).

### Issue #2 (Assign Me) — ✅ ĐÃ XONG
- Lambda fix đã deploy (verify lúc 17:27, đủ 6 hàm Slack→email→Jira accountId→assignJiraTicket).
- Đã xác nhận qua CloudWatch log: TRIAGE-84 "Self-assign succeeded" với accountId thật.

---

## 5. Commit liên quan (nhánh feature/ai-engine)
- `feat(triage-hub)`: fix Issue #1 data + #2 self-assign + CI auto-bump
- `fix(jira-dispatcher)`: null-safety response
- `fix(ci)`: smoke test dùng đúng tên SQS FIFO (.fifo)
- `test(verify)`: fix CDO test suite + harden resolver + gitignore secrets

---

## 6. Lệnh tái kiểm tra (cho bạn tự verify)

```bash
# AI engine
cd capstone/tf-1/devops/app/ai-engine
python -m ruff check app && python -m pytest tests/ -q

# Lambda alert-ingest
cd tests/local && npm install && npx jest

# Resolver
python -m ruff check scripts/assignee_resolver/resolve_assignees.py
python -m bandit -r scripts/assignee_resolver -ll

# Terraform
cd capstone/tf-1/devops/infra/environments/sandbox
terraform init -backend=false && terraform validate
```
