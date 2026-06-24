# =============================================================================
# Environment: dev
# Module composition — gọi các shared modules
# =============================================================================

# 1. Platform VPC Module
module "vpc_platform" {
  source = "../../modules/vpc"

  vpc_name                = "triage-platform-vpc-${var.environment}"
  cidr_block              = var.platform_vpc_cidr
  public_subnets          = [cidrsubnet(var.platform_vpc_cidr, 8, 0), cidrsubnet(var.platform_vpc_cidr, 8, 1)]
  private_subnets         = [cidrsubnet(var.platform_vpc_cidr, 8, 10), cidrsubnet(var.platform_vpc_cidr, 8, 11)]
  enable_nat_gateway      = true
  enable_internet_gateway = true
  environment             = var.environment

  # SUGGEST: Thay cidrsubnet() bằng explicit CIDR trong terraform.tfvars
  # Lý do: cidrsubnet(var.platform_vpc_cidr, 8, 0) là "magic number" — khó đọc, khó audit
  # Tham khảo: TERRAFORM_BEST_PRACTICES.md §2
  #
  # Ví dụ:
  # public_subnets = var.platform_public_subnets   # ["10.0.0.0/24", "10.0.1.0/24"]
  # private_subnets = var.platform_private_subnets  # ["10.0.10.0/24", "10.0.11.0/24"]
}

# 2. Customer VPC Module (Simulating Customer Environment)
module "vpc_customer" {
  source = "../../modules/vpc"

  vpc_name                = "triage-customer-vpc-${var.environment}"
  cidr_block              = var.customer_vpc_cidr
  public_subnets          = [cidrsubnet(var.customer_vpc_cidr, 8, 0), cidrsubnet(var.customer_vpc_cidr, 8, 1)]
  private_subnets         = []
  enable_nat_gateway      = false
  enable_internet_gateway = true
  environment             = var.environment
}

# 3. Customer App Simulation EC2 Module
module "customer_app" {
  source = "../../modules/customer_app"

  vpc_id      = module.vpc_customer.vpc_id
  subnet_id   = module.vpc_customer.public_subnet_ids[0]
  environment = var.environment

  # SUGGEST: Truyền instance_type từ variable thay vì dùng default trong module
  # instance_type = var.customer_instance_type
}
