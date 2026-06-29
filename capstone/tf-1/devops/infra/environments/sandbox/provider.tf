terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "triage-hub-tfstate-bucket"
    key          = "sandbox/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "triage-hub"
      triage-hub  = "true"
      ManagedBy   = "Terraform"
      Environment = var.environment
      Owner       = "CDO-09"
    }
  }
}

# ArgoCD bootstrap: ci-infra.yml → job bootstrap-argocd sẽ tự chạy:
#   aws eks update-kubeconfig → helm install argocd → kubectl apply root-app.yaml
# Không dùng kubernetes/helm provider ở đây để tránh lỗi EKS token hết hạn
