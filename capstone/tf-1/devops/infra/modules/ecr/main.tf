# =============================================================================
# ECR Repository — Best Practice Sample
# Pattern: for_each multi-repo, IMMUTABLE tags, lifecycle cleanup
# =============================================================================

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = "${var.project_name}-${each.key}"
  image_tag_mutability = "IMMUTABLE" # Invariant: prevent tag overwrite

  image_scanning_configuration {
    scan_on_push = true # Invariant: always scan
  }

  tags = {
    Name = "${var.project_name}-${each.key}"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = var.repositories
  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Giữ lại ${each.value.max_image_count} image mới nhất"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = each.value.max_image_count
      }
      action = { type = "expire" }
    }]
  })
}
