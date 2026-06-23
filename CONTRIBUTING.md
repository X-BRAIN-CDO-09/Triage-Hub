# Hướng dẫn Đóng góp Code & Quy trình Git (Contributing Guidelines)

Chào mừng bạn đến với dự án Triage Hub! Để đảm bảo mã nguồn sạch sẽ, dễ tích hợp và an toàn, tất cả thành viên trong nhóm cần tuân thủ quy trình Git dưới đây.

---

## 1. Quy tắc đặt tên Branch (Nhánh)

Trước khi bắt đầu code một tính năng hay sửa một lỗi, hãy tạo một nhánh mới từ nhánh `main` mới nhất:

* **Tính năng mới:** `feature/<tên-thành-viên>-<tên-ngắn-của-task>`
  * *Ví dụ:* `feature/phong-jira-api`, `feature/hoang-slack-bot`
* **Sửa lỗi thường:** `bugfix/<tên-thành-viên>-<tên-lỗi>`
  * *Ví dụ:* `bugfix/hoang-slack-button-payload`
* **Sửa lỗi khẩn cấp (Hotfix):** `hotfix/<tên-lỗi>`

---

## 2. Quy tắc viết Commit Message (Conventional Commits)

Commit message là nhật ký của dự án, giúp cả nhóm và Mentor dễ dàng theo dõi tiến độ. Hãy viết commit theo format:

```text
<type>(<phạm-vi-thay-đổi>): <mô tả ngắn bằng tiếng Anh hoặc tiếng Việt>
```

### Các `type` được chấp nhận:
* `feat`: Thêm tính năng mới (Ví dụ: `feat(jira): thêm hàm tạo ticket tự động`)
* `fix`: Sửa lỗi (Ví dụ: `fix(slack): sửa lỗi parse webhook`)
* `docs`: Cập nhật tài liệu (Ví dụ: `docs(ai): hoàn thành spec contract`)
* `refactor`: Tái cấu trúc code nhưng không đổi logic (Ví dụ: `refactor(platform): tối ưu hàm gọi telemetry`)
* `style`: Thay đổi định dạng code (khoảng trắng, format...) không ảnh hưởng logic.
* `test`: Thêm hoặc sửa các file test (Ví dụ: `test(ai): viết test case cho scenario 1`)
* `chore`: Các việc vặt như setup cấu hình, build tool, gitignore... (Ví dụ: `chore: setup gitignore`)

---

## 3. Quy trình gửi và duyệt Pull Request (PR)

1. **Tuyệt đối không push trực tiếp vào nhánh `main`** (nhánh `main` đã được bảo vệ).
2. Tạo nhánh feature/bugfix tương ứng, code và chạy thử kỹ càng ở local.
3. Push nhánh đó lên remote GitHub.
4. Tạo Pull Request (PR) từ nhánh của bạn vào `main`.
5. Điền đầy đủ thông tin vào biểu mẫu PR mẫu tự động sinh ra (Mô tả, link Jira task, kết quả test local).
6. Tag hoặc thông báo cho Tech Lead và các bạn trong nhóm để review.
7. Yêu cầu ít nhất **1 approval** để có thể merge PR vào `main`.
