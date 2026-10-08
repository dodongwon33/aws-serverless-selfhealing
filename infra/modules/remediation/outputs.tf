output "param_names" {
  value = { for k, p in aws_ssm_parameter.this : k => p.name }
}

output "freeze_param_arn" {
  value = aws_ssm_parameter.this["freeze"].arn
}

output "function_name" {
  value = module.function.function_name
}
