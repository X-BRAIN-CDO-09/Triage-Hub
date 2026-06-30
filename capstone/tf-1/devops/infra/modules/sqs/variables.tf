variable "project_name" {
  type        = string
  description = "Project name prefix for resources"
}

variable "queues" {
  type = map(object({
    visibility_timeout_seconds = optional(number, 30)
    message_retention_seconds  = optional(number, 345600) # 4 days
    max_receive_count          = optional(number, 5)
  }))
  description = "Map of SQS queue configurations to create along with their DLQs"
}
