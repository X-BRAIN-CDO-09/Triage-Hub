output "secret_arns" {
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.arn }
  description = "ARNs of the created secrets"
}

output "secret_ids" {
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.id }
  description = "IDs of the created secrets"
}
