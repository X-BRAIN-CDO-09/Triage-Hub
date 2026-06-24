variable "aws_region" {
  type        = string
  description = "AWS Region to deploy resources"
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
  description = "Environment name (e.g. dev, staging, prod)"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment phải là dev, staging, hoặc prod."
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
