output "api_url" {
  value = module.api.invoke_url
}

output "api_key" {
  value     = module.api.api_key
  sensitive = true
}

output "function_name" {
  value = module.app.function_name
}

output "alias_name" {
  value = module.app.alias_name
}

output "codedeploy_app" {
  value = module.deploy.app_name
}

output "codedeploy_group" {
  value = module.deploy.deployment_group_name
}

output "ssm_params" {
  value = module.remediation.param_names
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${module.monitoring.dashboard_name}"
}
