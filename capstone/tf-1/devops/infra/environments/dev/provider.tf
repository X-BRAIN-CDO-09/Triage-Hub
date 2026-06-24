terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "triage-hub-tfstate-bucket"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true

    # SUGGEST: Thêm DynamoDB lock table cho team collaboration
    # dynamodb_table = "triage-hub-tf-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project    = "triage-hub"
      triage-hub = "true"
      ManagedBy  = "Terraform"

      # SUGGEST: Thêm Environment tag động từ variable
      # Environment = var.environment
      # SUGGEST: Thêm Owner tag
      # Owner = "CDO-09"
    }
  }
}
