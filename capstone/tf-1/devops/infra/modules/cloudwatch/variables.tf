variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., sandbox, prod)"
  type        = string
}

variable "retention_in_days" {
  description = "Number of days to retain logs in CloudWatch"
  type        = number
  default     = 14
}
