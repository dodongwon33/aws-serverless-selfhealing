output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "initial_version" {
  value = aws_lambda_function.this.version
}

output "alias_name" {
  value = aws_lambda_alias.live.name
}

output "alias_invoke_arn" {
  value = aws_lambda_alias.live.invoke_arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
