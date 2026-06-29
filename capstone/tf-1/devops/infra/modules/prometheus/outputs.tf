output "prometheus_namespace" {
  value       = helm_release.kube_prometheus_stack.namespace
  description = "Kubernetes namespace where Prometheus is deployed"
}

output "prometheus_service_name" {
  value       = "prometheus-operated"
  description = "Internal Kubernetes service name for Prometheus"
}

output "prometheus_endpoint" {
  value       = "http://prometheus-operated.monitoring:9090"
  description = "Internal endpoint for Prometheus remote_write or query"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN of the SNS topic used for alert notifications"
}

output "sns_subscription_email" {
  value       = var.alertmanager_notification_email
  description = "Email address subscribed to the SNS alert topic"
}
