variable "vpc_name" {
  type        = string
  description = "Name tag for the VPC"
}

variable "cidr_block" {
  type        = string
  description = "CIDR block for the VPC"
}

variable "public_subnets" {
  type        = list(string)
  description = "List of public subnet CIDRs"
  default     = []
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnet CIDRs"
  default     = []
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
