# 런타임 보호: 배포 이후(카나리 우회 핫픽스, 운영 중 드러난 결함)에 알람 → EventBridge → alias 롤백

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  params = {
    stable   = { name = "${var.ssm_prefix}/stable-version", value = var.initial_version }
    previous = { name = "${var.ssm_prefix}/previous-version", value = "none" }
    freeze   = { name = "${var.ssm_prefix}/deploy-freeze", value = "false" }
  }
}

# 표준 파라미터 = 무료. 값은 CI/remediation이 소유하므로 Terraform은 생성만 한다.
resource "aws_ssm_parameter" "this" {
  for_each = local.params
  name     = each.value.name
  type     = "String"
  value    = each.value.value

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_iam_policy_document" "remediation" {
  statement {
    actions   = ["lambda:GetAlias", "lambda:UpdateAlias"]
    resources = [var.function_arn, "${var.function_arn}:*"]
  }
  statement {
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [for p in aws_ssm_parameter.this : p.arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }
  statement {
    actions   = ["codedeploy:ListDeployments"]
    resources = ["arn:aws:codedeploy:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:deploymentgroup:${var.codedeploy_app}/${var.codedeploy_group}"]
  }
}

module "function" {
  source             = "../lambda_function"
  name               = "${var.name}-remediation"
  source_dir         = var.source_dir
  handler            = "remediation.handler"
  policy_json        = data.aws_iam_policy_document.remediation.json
  boundary_arn       = var.boundary_arn
  role_path          = var.role_path
  log_retention_days = var.log_retention_days
  environment = {
    FUNCTION_NAME    = var.function_name
    ALIAS_NAME       = var.alias_name
    STABLE_PARAM     = aws_ssm_parameter.this["stable"].name
    PREVIOUS_PARAM   = aws_ssm_parameter.this["previous"].name
    FREEZE_PARAM     = aws_ssm_parameter.this["freeze"].name
    ALERTS_TOPIC_ARN = var.alerts_topic_arn
    CODEDEPLOY_APP   = var.codedeploy_app
    CODEDEPLOY_GROUP = var.codedeploy_group
  }
}

# AWS 서비스 이벤트(알람 상태 변경)는 EventBridge 요금이 없다
resource "aws_cloudwatch_event_rule" "alarm" {
  name        = "${var.name}-alarm-to-remediation"
  description = "Rollback alarms entering ALARM state"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = var.alarm_names
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "remediation" {
  rule = aws_cloudwatch_event_rule.alarm.name
  arn  = module.function.function_arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 600
  }
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm.arn
}
