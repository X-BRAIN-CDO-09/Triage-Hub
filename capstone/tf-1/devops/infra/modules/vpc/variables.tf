variable "vpc_name" {
  type        = string
  description = "Name tag for the VPC"
}

variable "cidr_block" {
  type        = string
  description = "CIDR block for the VPC"

  # SUGGEST: Thêm validation CIDR format
  # validation {
  #   condition     = can(cidrhost(var.cidr_block, 0))
  #   error_message = "cidr_block phải là CIDR hợp lệ (vd: 10.0.0.0/16)."
  # }
}

variable "public_subnets" {
  type        = list(string)
  description = "List of public subnet CIDRs"
  default     = []

  # SUGGEST: Đổi type sang map(object) để dùng for_each + typed subnets
  # type = map(object({
  #   cidr_block        = string
  #   availability_zone = string
  #   type              = string  # "alb" hoặc "nat"
  # }))
  # validation {
  #   condition = alltrue([for s in values(var.public_subnets) : contains(["alb", "nat"], s.type)])
  #   error_message = "public_subnets type phải là 'alb' hoặc 'nat'."
  # }
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnet CIDRs"
  default     = []

  # SUGGEST: Tương tự public_subnets — đổi sang map(object)
  # type = map(object({
  #   cidr_block           = string
  #   availability_zone    = string
  #   type                 = string            # "app" hoặc "db"
  #   nat_gateway_route_to = optional(string)   # Key của NAT public subnet
  # }))
  # validation {
  #   condition = alltrue([for s in values(var.private_subnets) : contains(["app", "db"], s.type)])
  #   error_message = "private_subnets type phải là 'app' hoặc 'db'."
  # }
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Enable NAT Gateway"
  default     = false
}

variable "enable_internet_gateway" {
  type        = bool
  description = "Enable Internet Gateway"
  default     = false
}

variable "environment" {
  type        = string
  description = "Environment name"
}
