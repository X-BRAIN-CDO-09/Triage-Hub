output "repository_urls" {
  description = "Bản đồ URL của các ECR repository (key = tên repo)"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Bản đồ ARN của các ECR repository (key = tên repo)"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}
