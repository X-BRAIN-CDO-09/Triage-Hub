output "queue_arns" {
  value       = { for k, v in aws_sqs_queue.this : k => v.arn }
  description = "ARNs of the SQS queues"
}

output "queue_urls" {
  value       = { for k, v in aws_sqs_queue.this : k => v.url }
  description = "URLs of the SQS queues"
}

output "dlq_arns" {
  value       = { for k, v in aws_sqs_queue.dlq : k => v.arn }
  description = "ARNs of the SQS DLQs"
}
