output "invoke_url" {
  value       = aws_api_gateway_stage.this.invoke_url
  description = "The URL to invoke the API Gateway stage"
}

output "execution_arn" {
  value       = aws_api_gateway_rest_api.this.execution_arn
  description = "The Execution ARN of the API Gateway"
}

output "api_key_value" {
  value       = aws_api_gateway_api_key.this.value
  description = "The API key value for API Gateway"
  sensitive   = true
}
