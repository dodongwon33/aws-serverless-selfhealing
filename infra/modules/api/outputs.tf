output "invoke_url" {
  value = aws_api_gateway_stage.this.invoke_url
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "api_name" {
  value = aws_api_gateway_rest_api.this.name
}

output "stage_name" {
  value = aws_api_gateway_stage.this.stage_name
}

output "access_log_group_name" {
  value = aws_cloudwatch_log_group.access.name
}

output "api_key" {
  value     = aws_api_gateway_api_key.this.value
  sensitive = true
}
