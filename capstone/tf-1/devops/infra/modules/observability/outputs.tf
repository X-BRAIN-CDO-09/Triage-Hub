output "sns_topic_arn" {
  description = "The ARN of the SNS topic for observability alerts"
  value       = var.enable_notifications ? aws_sns_topic.alerts[0].arn : ""
}

output "dashboard_name" {
  description = "The name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
