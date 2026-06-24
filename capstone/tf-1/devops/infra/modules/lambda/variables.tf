variable "project_name" {
  description = "Tên dự án để gán tag và định danh tài nguyên"
  type        = string
}

variable "lambdas" {
  description = "Bản đồ cấu hình các hàm Lambda. Key là định danh duy nhất của mỗi Lambda."
  type = map(object({
    handler                = string
    runtime                = string
    memory_size            = optional(number, 128)
    timeout                = optional(number, 30)
    reserved_concurrency   = optional(number, -1) # -1 = unreserved
    environment_variables  = optional(map(string), {})
    vpc_subnet_ids         = optional(list(string))
    vpc_security_group_ids = optional(list(string))
    s3_bucket              = optional(string)
    s3_key                 = optional(string)
    source_dir             = optional(string)
    local_zip_path         = optional(string)
    iam_policy_statements = optional(list(object({
      effect    = string
      actions   = list(string)
      resources = list(string)
    })), [])
  }))

  validation {
    condition = alltrue([
      for k, v in var.lambdas :
      contains(["python3.12", "python3.11", "python3.10", "nodejs20.x", "nodejs18.x"], v.runtime)
    ])
    error_message = "Lambda runtime phải là một trong: python3.12, python3.11, python3.10, nodejs20.x, nodejs18.x."
  }

  validation {
    condition = alltrue([
      for k, v in var.lambdas :
      v.memory_size >= 128 && v.memory_size <= 10240
    ])
    error_message = "Lambda memory_size phải trong khoảng 128-10240 MB."
  }
}

variable "default_vpc_subnet_ids" {
  description = "Danh sách subnet IDs mặc định cho tất cả Lambda chạy trong VPC (có thể ghi đè per-lambda)"
  type        = list(string)
  default     = null
}

variable "default_vpc_security_group_ids" {
  description = "Danh sách security group IDs mặc định cho tất cả Lambda trong VPC (có thể ghi đè per-lambda)"
  type        = list(string)
  default     = null
}
