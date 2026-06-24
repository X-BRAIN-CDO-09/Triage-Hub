# =============================================================================
# Security Group — Best Practice Sample
# Pattern: Reusable dynamic SG, no hardcoded 0.0.0.0/0, description required
# =============================================================================

resource "aws_security_group" "this" {
  name        = "${var.project_name}-${var.name_suffix}-sg"
  description = var.description
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      cidr_blocks     = length(ingress.value.cidr_blocks) > 0 ? ingress.value.cidr_blocks : null
      security_groups = length(ingress.value.security_groups) > 0 ? ingress.value.security_groups : null
      description     = ingress.value.description
    }
  }

  dynamic "egress" {
    for_each = var.egress_rules
    content {
      from_port       = egress.value.from_port
      to_port         = egress.value.to_port
      protocol        = egress.value.protocol
      cidr_blocks     = length(egress.value.cidr_blocks) > 0 ? egress.value.cidr_blocks : null
      security_groups = length(egress.value.security_groups) > 0 ? egress.value.security_groups : null
      description     = egress.value.description
    }
  }

  tags = {
    Name = "${var.project_name}-${var.name_suffix}-sg"
  }
}
