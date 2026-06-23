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
