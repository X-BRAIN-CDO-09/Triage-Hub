aws_region   = "us-east-1"
environment  = "sandbox"
project_name = "triage-hub"

platform_vpc_cidr        = "10.0.0.0/16"
platform_public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
platform_private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

customer_vpc_cidr       = "10.1.0.0/16"
customer_public_subnets = ["10.1.1.0/24"]

customer_instance_type = "t3.large"
cluster_version        = "1.30"
node_instance_types    = ["t3.large"]

node_scaling = {
  min_size     = 2
  max_size     = 4
  desired_size = 2
}

public_access_cidrs = ["0.0.0.0/0"]
