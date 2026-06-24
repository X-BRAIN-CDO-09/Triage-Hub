variable "project_name" {
  description = "Tên dự án để gán tag"
  type        = string
}

variable "vpc_id" {
  description = "ID của VPC nơi Security Group được tạo"
  type        = string
}

variable "name_suffix" {
  description = "Hậu tố tên Security Group (vd: lambda, ecs, rds)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name_suffix))
    error_message = "name_suffix chỉ chấp nhận lowercase, numbers, và hyphens."
  }
}

variable "description" {
  description = "Mô tả của Security Group"
  type        = string
  default     = "Managed by Terraform"
}

variable "ingress_rules" {
  description = "Danh sách luật inbound"
  type = list(object({
    from_port       = number
    to_port         = number
    protocol        = string
    cidr_blocks     = optional(list(string), [])
    security_groups = optional(list(string), [])
    description     = string # Bắt buộc — phải giải thích lý do mở port
  }))
  default = []

  validation {
    condition = alltrue([
      for rule in var.ingress_rules : rule.description != ""
    ])
    error_message = "Mỗi ingress rule phải có description giải thích lý do mở port."
  }
}

variable "egress_rules" {
  description = "Danh sách luật outbound"
  type = list(object({
    from_port       = number
    to_port         = number
    protocol        = string
    cidr_blocks     = optional(list(string), [])
    security_groups = optional(list(string), [])
    description     = string
  }))
  default = [{
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }]
}
