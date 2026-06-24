# SUGGEST: Env-specific variables KHÔNG nên có default
# Lý do: force operator phải define trong terraform.tfvars → tránh dùng nhầm config dev cho prod
# Tham khảo: TERRAFORM_BEST_PRACTICES.md §4

variable "aws_region" {
  type        = string
  description = "AWS Region to deploy resources"
  default     = "us-east-1"
  # SUGGEST: Xóa default, define trong terraform.tfvars
}

variable "platform_vpc_cidr" {
  type        = string
  description = "CIDR block for the Platform VPC"
  default     = "10.0.0.0/16"
  # SUGGEST: Xóa default, define trong terraform.tfvars
  # SUGGEST: Thêm validation CIDR format:
  # validation {
  #   condition     = can(cidrhost(var.platform_vpc_cidr, 0))
  #   error_message = "platform_vpc_cidr phải là CIDR hợp lệ (vd: 10.0.0.0/16)."
  # }
}

variable "customer_vpc_cidr" {
  type        = string
  description = "CIDR block for the Customer VPC"
  default     = "10.1.0.0/16"
  # SUGGEST: Xóa default, define trong terraform.tfvars
  # SUGGEST: Thêm validation tương tự platform_vpc_cidr
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, staging, prod)"
  default     = "dev"
  # SUGGEST: Xóa default, define trong terraform.tfvars
  # SUGGEST: Thêm validation:
  # validation {
  #   condition     = contains(["dev", "staging", "prod"], var.environment)
  #   error_message = "environment phải là dev, staging, hoặc prod."
  # }
}
