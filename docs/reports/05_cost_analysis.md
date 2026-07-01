<!-- Doc owner: Nhóm CDO-09
     Status: Measured actual (W12 T4 Pack #2)
     Word target: 800-1500 từ -->

## 1. Cost model per tenant (forecast) (Owner: Nhật)

Dựa trên kiến trúc hạ tầng thực tế đã được Terraform triển khai, chi phí tài nguyên chia làm 2 phần: **Fixed Cost** (Hạ tầng dùng chung) và **Variable Cost** (Chi phí phát sinh trên mỗi Tenant).
Giả định một Tenant có lưu lượng xử lý trung bình **10,000 alerts/tháng**.

### 1.1 Chi phí cố định (Shared Fixed Infra Cost / Month)
- **EKS Control Plane**: $73.00
- **EKS Worker Nodes** (2 x `t3.large` on us-east-1): $121.00
- **Storage** (EBS gp3 cho 2 nodes): $3.20
- **Networking** (1 ALB, 1 NAT Gateway, 2 VPC Interface Endpoints cho Bedrock/SQS): ~$63.45
- **Observability Baseline** (CloudWatch Dashboards + 18 Alarms): ~$4.80
- **Tổng Fixed Cost**: **~$265.45/tháng**

### 1.2 Chi phí biến đổi (Variable Cost / Tenant / Month)

| Component | Unit cost (us-east-1) | Tenant avg usage | $/tenant/month |
|---|---|---|---|
| Compute (Lambda) | $0.20 / 1M reqs | 30,000 reqs (3 functions) | ~$0.01 |
| Messaging (API GW, SQS) | API: $3.50/1M, SQS: $0.40/1M | 10k API, 20k SQS reqs | ~$0.05 |
| Database (DynamoDB On-demand) | $1.25/1M Write, $0.25/1M Read | 10k writes, 10k reads | ~$0.02 |
| Storage (S3, ECR) | S3: $0.023/GB-month | 5 GB | ~$0.12 |
| AI inference (Bedrock - Claude 3 Haiku) | ~$0.0005 / alert (trung bình) | 10,000 alerts | ~$5.00 |
| Security (Secrets Manager) | $0.40/secret/month | 2 secrets (Jira, Slack) | $0.80 |
| Observability (CloudWatch Logs) | $0.50 / GB ingested | 1 GB log data | ~$0.50 |
| **Total Variable / tenant / month** | | | **~$6.50** |

## 2. Cost at scale (Owner: Nhật)

Chi phí trung bình cho mỗi Tenant sẽ giảm dần nhờ vào sự san sẻ (amortize) mức Fixed Cost của hệ thống lõi (EKS, VPC).

| Tenant count | Fixed Cost | Variable Cost ($6.50 * N) | Monthly total cost | Avg per-tenant |
|---|---|---|---|---|
| 10 | $265.45 | $65.00 | **$330.45** | **$33.05** |
| 50 | $265.45 | $325.00 | **$590.45** | **$11.81** |
| 200 | $400.00 (Scale EC2 nodes) | $1,300.00 | **$1,700.00** | **$8.50** |

*Lưu ý: Tại mốc 200 tenants, Cluster sẽ cần scale số lượng Worker Nodes lên để đáp ứng tải (KEDA Auto Scaling).*

## 3. Cost optimization applied (Owner: Nhật)

Dưới đây là các phương pháp tối ưu hóa chi phí đã được áp dụng hoặc đưa vào Roadmap triển khai thực tế trong mã nguồn Terraform:

- [ ] Spot instances cho non-critical workload trên EKS (~70% saving)
- [ ] Reserved capacity/Savings Plan cho EKS baseline
- [x] DynamoDB on-demand vs provisioned cho bảng dữ liệu chính (Dùng On-demand để tối ưu cho unpredictable load của Triage Hub).
- [x] Data transfer optimization: Đã sử dụng VPC Interface Endpoints cho Bedrock và SQS để định tuyến traffic bên trong AWS, tránh phí NAT Gateway đắt đỏ.
- [x] Tối ưu hóa API Gateway Cache và SQS Batching để giảm số lượng request gọi vào Lambda và Bedrock.
- [ ] Right-sizing cho EKS pods và Lambda memory
- [ ] Log retention tiering cho hệ thống Observability

## 4. Cost vs alternatives (cùng task force) (Owner: Nhật)

| Angle | $/tenant/month forecast | Why diff |
|---|---|---|
| Kiến trúc Serverless 100% (Không EKS) | ~$10 - $15 | Không mất ~$265 Fixed Cost EKS/VPC ban đầu, rất rẻ ở Scale nhỏ. Tuy nhiên khi lên Scale lớn, Bedrock Agents + Lambda concurrency cost sẽ tăng tuyến tính mạnh. |
| Kiến trúc EKS Hybrid (Triage-Hub hiện tại) | ~$8.50 ở Scale 200 | Mất Fixed Cost ban đầu nhưng khả năng tùy biến Agent Core cao hơn, cho phép nhồi nhét nhiều AI workload vào các Spot instances để tiết kiệm. |

## 5. Measured actual (Pack #2 only - fill in W12) (Owner: Nhật & Thi)

### 5.1 2-week capstone spend (Thực tế triển khai)

| Service | Forecast (per month) | Actual (2-week test) | Delta |
|---|---|---|---|
| Compute (EKS/EC2) | $194.00 | $90.00 | - |
| Database & Messaging | $15.00 | $2.50 | - |
| Networking (VPC/NAT/ALB) | $63.45 | $30.00 | - |
| AI inference (Bedrock) | $20.00 | $5.00 | - |
| Observability | $15.00 | $3.50 | - |
| **Total** | **$307.45** | **$131.00** | - |

### 5.2 Cost-per-correct-decision (joint with AI eval)

| Metric | Value |
|---|---|
| Total AI calls in capstone | 1,000 |
| Correct decisions | 850 |
| Total AI cost (Bedrock + Network) | $5.00 |
| **Cost per correct decision** | **~$0.0058** |

## 6. Cost guardrails (Owner: Nhật)

- Monthly budget alert at 70%, 90%, 100% bằng AWS Budgets.
- Per-tenant quota enforced via API Gateway Usage Plans (Throttling / Quota).
- CloudWatch Alarms để cảnh báo nếu số lượng request tới Bedrock vượt quá định mức (Spike detection).

## 7. Cost recommendations for production (Owner: Nhật)

- Mua Compute Savings Plan cho EKS và Lambda sau 3 tháng có usage baseline ổn định.
- Triển khai **Karpenter** thay cho Cluster Autoscaler để tận dụng Spot Instances rẻ nhất cho Agent Core.
- Cross-region replication cho S3/DynamoDB chỉ bật cho Enterprise tier.
- Đặt thời gian tự xóa Log (Retention Policy) cho CloudWatch Logs về mức 30 ngày để tránh tốn phí lưu trữ rác theo thời gian.

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Infra design drives compute/storage cost
- [`../../ai/docs/03_ai_engine_spec.md`](../../ai/docs/03_ai_engine_spec.md) §8 - AI inference cost feeds row "AI inference" trong §1 doc này
- [`07_test_eval_report.md`](07_test_eval_report.md) - Load test results validate cost assumptions
