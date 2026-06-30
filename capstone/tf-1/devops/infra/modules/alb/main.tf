resource "aws_lb" "ai_engine_internal" {
  name               = "${var.project_name}-ai-alb-${var.environment}"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [var.alb_security_group_id]

  tags = {
    Name        = "${var.project_name}-ai-alb-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "ai_engine" {
  name        = "${var.project_name}-ai-tg-${var.environment}"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name        = "${var.project_name}-ai-tg-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_lb_listener" "ai_engine" {
  load_balancer_arn = aws_lb.ai_engine_internal.arn
  port              = 8080
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_engine.arn
  }
}
