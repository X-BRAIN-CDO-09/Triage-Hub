variable "project_name" {
  type        = string
  description = "Project name prefix for resources"
}

variable "environment" {
  type        = string
  description = "Deployment environment name"
  validation {
    condition     = contains(["dev", "staging", "sandbox", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, sandbox, prod."
  }
}

variable "integrations" {
  type = map(object({
    path_part           = string
    http_method         = string
    lambda_function_arn = string
    lambda_name         = string
    api_key_required    = optional(bool, false)
  }))
  description = "Map of API Gateway endpoints and their target Lambda ARNs"
}
