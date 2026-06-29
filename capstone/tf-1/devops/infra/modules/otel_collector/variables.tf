variable "cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "eks_log_group_name" {
  description = "The CloudWatch Log Group for EKS container logs"
  type        = string
}

variable "environment" {
  description = "Deployment environment (sandbox, staging, prod)"
  type        = string
  default     = "sandbox"
}
