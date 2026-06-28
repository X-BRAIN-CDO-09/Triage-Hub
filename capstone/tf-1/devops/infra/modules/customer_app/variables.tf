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
  default     = "t3.large"
}

variable "api_gateway_url" {
  type        = string
  description = "The API Gateway URL to forward alerts to"
}

variable "api_key" {
  type        = string
  description = "The API Key for API Gateway authentication"
  sensitive   = true
}

variable "tenant_id" {
  type        = string
  description = "The ID of the tenant for this customer app deployment"
  default     = "tenant-a"
}

variable "allowed_inbound_cidrs" {
  type        = list(string)
  description = "List of public CIDR blocks (e.g. NAT Gateway public IPs) allowed to access monitoring services"
}

