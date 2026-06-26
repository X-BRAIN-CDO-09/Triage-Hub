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
