variable "vpc_id" {
  type        = string
  description = "The ID of the Customer VPC"
}

variable "subnet_id" {
  type        = string
  description = "The Subnet ID in Customer VPC to deploy the EC2 instance"
}

variable "environment" {
  type        = string
  description = "Environment name"
}

variable "instance_type" {
  type        = string
  description = "EC2 Instance type"
  default     = "t3.micro"
}
