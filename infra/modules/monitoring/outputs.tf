output "rollback_alarm_names" {
  description = "자동 롤백(CodeDeploy + 런타임 remediation)을 트리거하는 알람"
  value       = [aws_cloudwatch_metric_alarm.api_5xx_rate.alarm_name, aws_cloudwatch_metric_alarm.lambda_errors.alarm_name]
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}
