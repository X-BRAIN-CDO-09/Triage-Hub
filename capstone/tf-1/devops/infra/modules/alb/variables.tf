variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. sandbox, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the ALB will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnets to deploy the ALB into"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID for the load balancer"
  type        = string
}
