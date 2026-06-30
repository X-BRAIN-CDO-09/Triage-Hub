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

variable "secrets" {
  type        = map(string)
  description = "Map of secret keys to create in Secrets Manager, values are description labels"
  default = {
    "service_auth_token"   = "Token for service to service auth fallback"
    "slack_signing_secret" = "Slack application signing secret"
    "jira_api_token"       = "Jira API credentials token"
    "slack_bot_token"      = "Slack bot token for sending notifications"
  }
}
