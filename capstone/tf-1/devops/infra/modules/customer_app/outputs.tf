output "instance_id" {
  value       = aws_instance.spot_instance.id
  description = "The ID of the Customer App EC2 instance"
}

output "public_ip" {
  value       = aws_instance.spot_instance.public_ip
  description = "The public IP of the Customer App EC2 instance"
}

output "public_dns" {
  value       = aws_instance.spot_instance.public_dns
  description = "The public DNS of the Customer App EC2 instance"
}
