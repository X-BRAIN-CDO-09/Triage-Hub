output "secret_arns" {
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.arn }
  description = "ARNs of the created secrets"
}

output "secret_ids" {
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.id }
  description = "IDs of the created secrets"
}

output "ai_engine_secret_arn" {
  value       = aws_secretsmanager_secret.ai_engine.arn
  description = "ARN secret triage-hub/ai-engine — engine ESO + push-to-ai đọc chung"
}
