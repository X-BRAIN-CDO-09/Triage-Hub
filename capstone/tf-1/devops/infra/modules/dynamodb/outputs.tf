output "table_name" {
  value       = aws_dynamodb_table.this.name
  description = "The name of the DynamoDB table"
}

output "table_arn" {
  value       = aws_dynamodb_table.this.arn
  description = "The ARN of the DynamoDB table"
}
