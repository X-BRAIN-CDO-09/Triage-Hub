output "triage_log_group_name" {
  value       = aws_cloudwatch_log_group.triage_logs.name
  description = "The name of the CloudWatch Log Group for lambdas"
}

output "eks_log_group_name" {
  value       = aws_cloudwatch_log_group.eks_logs.name
  description = "The name of the CloudWatch Log Group for EKS"
}

output "metrics_log_group_name" {
  value       = aws_cloudwatch_log_group.metrics_logs.name
  description = "The name of the CloudWatch Log Group for OTel metrics (EMF)"
}

output "dashboard_arn" {
  value       = aws_cloudwatch_dashboard.triage_dashboard.dashboard_arn
  description = "The ARN of the CloudWatch Dashboard"
}
