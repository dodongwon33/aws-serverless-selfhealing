data "aws_caller_identity" "current" {}

locals {
  name         = "${var.project}-${var.env}"
  role_path    = "/${var.project}/"
  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-workload-boundary"
  src          = "${path.root}/../../../src"
}

module "notification" {
  source      = "../../modules/notification"
  name        = local.name
  alert_email = var.alert_email
}

module "dynamodb" {
  source = "../../modules/dynamodb"
  name   = local.name
}

module "app" {
  source             = "../../modules/lambda_app"
  name               = "${local.name}-api"
  source_dir         = "${local.src}/app"
  table_name         = module.dynamodb.table_name
  table_arn          = module.dynamodb.table_arn
  layer_arns         = [var.powertools_layer_arn]
  boundary_arn       = local.boundary_arn
  role_path          = local.role_path
  log_retention_days = var.log_retention_days
}

module "api" {
  source             = "../../modules/api"
  name               = local.name
  function_name      = module.app.function_name
  alias_name         = module.app.alias_name
  alias_invoke_arn   = module.app.alias_invoke_arn
  rate_limit         = var.api_rate_limit
  burst_limit        = var.api_burst_limit
  quota_per_month    = var.api_quota_per_month
  log_retention_days = var.log_retention_days
  boundary_arn       = local.boundary_arn
  role_path          = local.role_path
}

module "monitoring" {
  source                = "../../modules/monitoring"
  name                  = local.name
  region                = var.region
  api_name              = module.api.api_name
  stage_name            = module.api.stage_name
  function_name         = module.app.function_name
  alias_name            = module.app.alias_name
  table_name            = module.dynamodb.table_name
  alerts_topic_arn      = module.notification.alerts_topic_arn
  lambda_log_group_name = module.app.log_group_name
  access_log_group_name = module.api.access_log_group_name
}

module "deploy" {
  source                = "../../modules/deploy"
  name                  = local.name
  deployment_group_name = "${local.name}-api"
  alarm_names           = module.monitoring.rollback_alarm_names
  boundary_arn          = local.boundary_arn
  role_path             = local.role_path
}

module "remediation" {
  source             = "../../modules/remediation"
  name               = local.name
  ssm_prefix         = "/${var.project}/${var.env}"
  source_dir         = "${local.src}/remediation"
  function_name      = module.app.function_name
  function_arn       = module.app.function_arn
  alias_name         = module.app.alias_name
  initial_version    = module.app.initial_version
  alarm_names        = module.monitoring.rollback_alarm_names
  codedeploy_app     = module.deploy.app_name
  codedeploy_group   = module.deploy.deployment_group_name
  alerts_topic_arn   = module.notification.alerts_topic_arn
  boundary_arn       = local.boundary_arn
  role_path          = local.role_path
  log_retention_days = var.log_retention_days
}

module "guardrails" {
  source             = "../../modules/guardrails"
  name               = local.name
  monthly_budget_usd = var.monthly_budget_usd
  alert_email        = var.alert_email
  rest_api_id        = module.api.rest_api_id
  stage_name         = module.api.stage_name
  freeze_param_name  = module.remediation.param_names["freeze"]
  freeze_param_arn   = module.remediation.freeze_param_arn
  alerts_topic_arn   = module.notification.alerts_topic_arn
  source_dir         = "${local.src}/killswitch"
  boundary_arn       = local.boundary_arn
  role_path          = local.role_path
  log_retention_days = var.log_retention_days
}
