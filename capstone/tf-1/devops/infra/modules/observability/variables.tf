variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. sandbox, dev, prod)"
  type        = string
}

variable "api_gateway_name" {
  description = "API Gateway name for metrics"
  type        = string
  default     = ""
}

variable "lambda_functions" {
  description = "List of lambda function names to monitor"
  type        = list(string)
  default     = []
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name"
  type        = string
  default     = ""
}

variable "sqs_queues" {
  description = "List of SQS Queue names for metrics"
  type        = list(string)
  default     = []
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster for ContainerInsights metrics (Optional)"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "notification_email" {
  description = "Email address for SNS notifications"
  type        = string
  default     = ""
}

variable "notification_sms" {
  description = "SMS number for SNS notifications (optional)"
  type        = string
  default     = ""
}

variable "enable_notifications" {
  description = "Enable SNS notifications for alarms"
  type        = bool
  default     = false
}

variable "alarm_thresholds" {
  description = "Thresholds for CloudWatch Alarms"
  type = object({
    api_gw_latency       = optional(number, 2000)
    api_gw_4xx_rate      = optional(number, 5)
    api_gw_5xx_rate      = optional(number, 1)
    lambda_error_rate    = optional(number, 1)
    lambda_duration      = optional(number, 5000)
    lambda_throttle_rate = optional(number, 1)
    sqs_queue_depth      = optional(number, 1000)
    sqs_oldest_message   = optional(number, 3600)
    dynamodb_throttle    = optional(number, 10)
    dynamodb_sys_error   = optional(number, 1)
  })
  default = {}
}
