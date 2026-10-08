# AWS에는 하드 지출 상한이 없다 → 다층 방어
#   1) API 사용량 계획 쿼터 (api 모듈)   : 요청 수 자체의 상한
#   2) Budgets 알림 50% / 예측 80%       : 사람에게 조기 경보
#   3) Budgets 실제 100% → 킬스위치       : API 스로틀 0 + 배포 동결

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_sns_topic" "budget" {
  name = "${var.name}-budget"
}

data "aws_iam_policy_document" "budget_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "budget" {
  arn    = aws_sns_topic.budget.arn
  policy = data.aws_iam_policy_document.budget_topic.json
}

data "aws_iam_policy_document" "killswitch" {
  statement {
    actions   = ["apigateway:PATCH"]
    resources = ["arn:aws:apigateway:${data.aws_region.current.region}::/restapis/${var.rest_api_id}/stages/${var.stage_name}"]
  }
  statement {
    actions   = ["ssm:PutParameter"]
    resources = [var.freeze_param_arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }
}

module "killswitch" {
  source             = "../lambda_function"
  name               = "${var.name}-killswitch"
  source_dir         = var.source_dir
  handler            = "killswitch.handler"
  policy_json        = data.aws_iam_policy_document.killswitch.json
  boundary_arn       = var.boundary_arn
  role_path          = var.role_path
  log_retention_days = var.log_retention_days
  environment = {
    REST_API_ID      = var.rest_api_id
    STAGE_NAME       = var.stage_name
    FREEZE_PARAM     = var.freeze_param_name
    ALERTS_TOPIC_ARN = var.alerts_topic_arn
  }
}

resource "aws_sns_topic_subscription" "killswitch" {
  topic_arn = aws_sns_topic.budget.arn
  protocol  = "lambda"
  endpoint  = module.killswitch.function_arn
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowBudgetTopicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.killswitch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget.arn
}

# 계정 전체 비용 기준 (이 프로젝트 외 리소스까지 포함해 "청구서"를 지킨다). 예산 2개까지 무료
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget.arn]
  }

  depends_on = [aws_sns_topic_policy.budget]
}
