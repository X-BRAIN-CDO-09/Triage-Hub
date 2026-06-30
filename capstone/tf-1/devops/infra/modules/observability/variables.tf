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
