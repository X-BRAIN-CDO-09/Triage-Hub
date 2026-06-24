output "function_arns" {
  description = "Bản đồ ARN của các Lambda function (key = tên lambda)"
  value       = { for k, v in aws_lambda_function.this : k => v.arn }
}

output "function_names" {
  description = "Bản đồ tên của các Lambda function (key = tên lambda)"
  value       = { for k, v in aws_lambda_function.this : k => v.function_name }
}

output "invoke_arns" {
  description = "Bản đồ invoke ARN để sử dụng với API Gateway (key = tên lambda)"
  value       = { for k, v in aws_lambda_function.this : k => v.invoke_arn }
}

output "role_arns" {
  description = "Bản đồ IAM Role ARN của các Lambda (key = tên lambda)"
  value       = { for k, v in aws_iam_role.this : k => v.arn }
}
