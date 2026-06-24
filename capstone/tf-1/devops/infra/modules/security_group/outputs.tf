output "security_group_id" {
  description = "ID của Security Group vừa tạo"
  value       = aws_security_group.this.id
}

output "security_group_arn" {
  description = "ARN của Security Group"
  value       = aws_security_group.this.arn
}
