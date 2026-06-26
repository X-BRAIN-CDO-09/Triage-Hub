output "alb_arn" {
  value       = aws_lb.ai_engine_internal.arn
  description = "The ARN of the ALB"
}

output "dns_name" {
  value       = aws_lb.ai_engine_internal.dns_name
  description = "The DNS name of the ALB"
}

output "target_group_arn" {
  value       = aws_lb_target_group.ai_engine.arn
  description = "The ARN of the target group"
}
