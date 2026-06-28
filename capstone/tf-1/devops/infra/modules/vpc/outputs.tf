output "vpc_id" {
  value       = aws_vpc.this.id
  description = "The ID of the VPC"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "List of IDs of public subnets"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "List of IDs of private subnets"
}

output "private_route_table_ids" {
  value       = aws_route_table.private[*].id
  description = "List of IDs of private route tables"
}

output "nat_public_ips" {
  value       = aws_eip.nat[*].public_ip
  description = "The public IP addresses of the NAT gateways"
}

output "public_route_table_ids" {
  value       = aws_route_table.public[*].id
  description = "List of IDs of public route tables"
}

