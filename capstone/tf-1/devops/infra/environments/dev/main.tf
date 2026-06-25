# =============================================================================
# Environment: dev
# Module composition — gọi các shared modules
# =============================================================================

# 1. Platform VPC Module
module "vpc_platform" {
  source = "../../modules/vpc"

  vpc_name                = "triage-platform-vpc-${var.environment}"
  cidr_block              = var.platform_vpc_cidr
  public_subnets          = var.platform_public_subnets
  private_subnets         = var.platform_private_subnets
  enable_nat_gateway      = true
  enable_internet_gateway = true
  environment             = var.environment
}

# 2. Customer VPC Module (Simulating Customer Environment)
module "vpc_customer" {
  source = "../../modules/vpc"

  vpc_name                = "triage-customer-vpc-${var.environment}"
  cidr_block              = var.customer_vpc_cidr
  public_subnets          = var.customer_public_subnets
  private_subnets         = []
  enable_nat_gateway      = false
  enable_internet_gateway = true
  environment             = var.environment
}

# 3. Customer App Simulation EC2 Module
module "customer_app" {
  source = "../../modules/customer_app"

  vpc_id        = module.vpc_customer.vpc_id
  subnet_id     = module.vpc_customer.public_subnet_ids[0]
  environment   = var.environment
  instance_type = var.customer_instance_type
}
