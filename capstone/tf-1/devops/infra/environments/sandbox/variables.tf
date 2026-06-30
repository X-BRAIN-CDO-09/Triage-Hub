variable "aws_region" {
  type        = string
  description = "AWS Region to deploy resources"
}

variable "project_name" {
  type        = string
  description = "Project name prefix for resources"
  default     = "triage-hub"
}

variable "platform_vpc_cidr" {
  type        = string
  description = "CIDR block for the Platform VPC"

  validation {
    condition     = can(cidrhost(var.platform_vpc_cidr, 0))
    error_message = "platform_vpc_cidr phải là CIDR hợp lệ (vd: 10.0.0.0/16)."
  }
}

variable "customer_vpc_cidr" {
  type        = string
  description = "CIDR block for the Customer VPC"

  validation {
    condition     = can(cidrhost(var.customer_vpc_cidr, 0))
    error_message = "customer_vpc_cidr phải là CIDR hợp lệ (vd: 10.1.0.0/16)."
  }
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. sandbox, staging, prod)"

  validation {
    condition     = contains(["sandbox", "staging", "prod"], var.environment)
    error_message = "environment phải là sandbox, staging, hoặc prod."
  }
}

variable "platform_public_subnets" {
  type        = list(string)
  description = "Public Subnet CIDRs for Platform VPC"
}

variable "platform_private_subnets" {
  type        = list(string)
  description = "Private Subnet CIDRs for Platform VPC"
}

variable "customer_public_subnets" {
  type        = list(string)
  description = "Public Subnet CIDRs for Customer VPC"
}

variable "customer_instance_type" {
  type        = string
  description = "Instance type for Customer App EC2"
  default     = "t3.large"
}

variable "cluster_version" {
  description = "EKS K8s control plane version"
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "Instance types for EKS managed node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_scaling" {
  description = "EKS node group scaling bounds"
  type = object({
    min_size     = number
    max_size     = number
    desired_size = number
  })
  default = {
    min_size     = 2
    max_size     = 6
    desired_size = 2
  }
}

variable "endpoint_public_access" {
  description = "Bật public API endpoint cho dev kubectl (sandbox). Production private-first = false."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "Allowed CIDR blocks for EKS public endpoint (chỉ khi endpoint_public_access = true)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_arns" {
  description = "Danh sách IAM User/Role ARN được cấp quyền admin vào EKS"
  type        = list(string)
  default     = []
}

variable "notification_email" {
  description = "Email address for SNS notifications"
  type        = string
  default     = "nhatphanhk102@gmail.com"
}

variable "notification_sms" {
  description = "SMS number for SNS notifications (optional)"
  type        = string
  default     = ""
}

variable "enable_notifications" {
  description = "Enable SNS notifications for alarms"
  type        = bool
  default     = true
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
