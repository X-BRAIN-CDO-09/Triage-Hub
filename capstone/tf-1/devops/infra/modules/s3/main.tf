# =============================================================================
# S3 Bucket for Artifact Storage (raw logs/metrics)
# =============================================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  # Sử dụng account id và env trong tên để đảm bảo globally unique
  bucket        = "${var.project_name}-artifacts-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment != "prod"

  tags = {
    Name = "${var.project_name}-artifacts-${var.environment}"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
