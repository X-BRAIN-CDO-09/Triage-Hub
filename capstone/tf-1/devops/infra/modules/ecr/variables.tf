variable "project_name" {
  description = "Tên dự án để gán tag và định danh tài nguyên"
  type        = string
}

variable "repositories" {
  description = "Bản đồ cấu hình các ECR repository. Key là tên repository."
  type = map(object({
    max_image_count = optional(number, 10)
  }))

  validation {
    condition = alltrue([
      for name, _ in var.repositories :
      can(regex("^[a-z0-9][a-z0-9._/-]*$", name))
    ])
    error_message = "Tên ECR repository chỉ chấp nhận lowercase, numbers, dots, hyphens, underscores, slashes."
  }
}
