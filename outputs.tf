output "alb_public_dns" {
  value = module.alb.this_lb_dns_name
}

output "alb_arn" {
  value = module.alb.this_lb_arn
}

output "target_group_arns" {
  value = module.alb.target_group_arns
}

output "asg_id" {
  value = module.asg.this_autoscaling_group_id
}