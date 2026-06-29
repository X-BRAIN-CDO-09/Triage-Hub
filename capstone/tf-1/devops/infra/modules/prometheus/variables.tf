variable "environment" {
  description = "Deployment environment (sandbox, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
}

variable "prometheus_storage_size" {
  description = "Persistent volume size for Prometheus data"
  type        = string
  default     = "20Gi"
}

variable "prometheus_retention" {
  description = "Data retention period for Prometheus"
  type        = string
  default     = "15d"
}

variable "alertmanager_webhook_url" {
  description = "Webhook URL to send alerts to (e.g. API Gateway endpoint)"
  type        = string
  default     = ""
}

variable "slack_webhook_url" {
  description = "Slack Webhook URL for AlertManager"
  type        = string
  default     = ""
}

variable "alertmanager_notification_email" {
  description = "Email address to subscribe to the SNS alert topic"
  type        = string
  default     = ""
}

variable "alertmanager_sns_topic_arn" {
  description = "SNS Topic ARN for alerts — populated from aws_sns_topic.alerts.arn output"
  type        = string
  default     = ""
}