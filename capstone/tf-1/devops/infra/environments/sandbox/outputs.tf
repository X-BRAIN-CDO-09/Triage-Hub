output "platform_vpc_id" {
  value       = module.vpc_platform.vpc_id
  description = "The ID of the Platform VPC"
}

output "customer_vpc_id" {
  value       = module.vpc_customer.vpc_id
  description = "The ID of the Customer VPC"
}

output "customer_ec2_public_ip" {
  value       = module.customer_app.public_ip
  description = "The public IP of the Customer App simulation EC2 instance"
}

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "The endpoint for EKS control plane"
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "The name of the EKS cluster"
}

output "apigw_invoke_url" {
  value       = module.api_gateway.invoke_url
  description = "The URL to invoke API Gateway"
}

output "sqs_queue_urls" {
  value       = module.sqs.queue_urls
  description = "The SQS queue URLs"
}

output "alb_target_group_arn" {
  value       = module.alb.target_group_arn
  description = "Internal ALB target group ARN — paste vào TargetGroupBinding (overlays/sandbox)"
}

output "dynamodb_table_name" {
  value       = module.dynamodb.table_name
  description = "The name of the DynamoDB table"
}
