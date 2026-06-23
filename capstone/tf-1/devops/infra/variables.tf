variable "aws_region" {
  type        = string
  description = "AWS Region to deploy resources"
  default     = "us-east-1"
}

variable "platform_vpc_cidr" {
  type        = string
  description = "CIDR block for the Platform VPC"
  default     = "10.0.0.0/16"
}

variable "customer_vpc_cidr" {
  type        = string
  description = "CIDR block for the Customer VPC"
  default     = "10.1.0.0/16"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, staging, prod)"
  default     = "dev"
}
