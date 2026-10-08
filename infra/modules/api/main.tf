# REST API (HTTP API가 아닌 이유: X-Ray 트레이싱 · 사용량 계획(쿼터)은 REST API만 지원)

resource "aws_api_gateway_rest_api" "this" {
  name = var.name

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_resource" "items" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "items"
}

resource "aws_api_gateway_resource" "item" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.items.id
  path_part   = "{id}"
}

locals {
  routes = {
    health_get = { resource_id = aws_api_gateway_resource.health.id, method = "GET" }
    items_post = { resource_id = aws_api_gateway_resource.items.id, method = "POST" }
    item_get   = { resource_id = aws_api_gateway_resource.item.id, method = "GET" }
  }
}

resource "aws_api_gateway_method" "this" {
  for_each         = local.routes
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = each.value.resource_id
  http_method      = each.value.method
  authorization    = "NONE"
  api_key_required = true # 사용량 계획 쿼터를 강제하기 위함 (키 없는 요청은 403)
}

resource "aws_api_gateway_integration" "this" {
  for_each                = local.routes
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = each.value.resource_id
  http_method             = aws_api_gateway_method.this[each.key].http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.alias_invoke_arn # $LATEST가 아닌 alias → 롤백/카나리가 실제로 트래픽에 반영됨
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.health.id,
      aws_api_gateway_resource.items.id,
      aws_api_gateway_resource.item.id,
      [for m in aws_api_gateway_method.this : [m.id, m.api_key_required]],
      [for i in aws_api_gateway_integration.this : [i.id, i.uri]],
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.this]
}

# 액세스 로그에는 계정 단위 CloudWatch 역할 설정이 필요하다 (리전당 1개, 계정 공유 설정)
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch" {
  name                 = "${var.name}-apigw-cloudwatch"
  path                 = var.role_path
  permissions_boundary = var.boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.cloudwatch.arn
  depends_on          = [aws_iam_role_policy_attachment.cloudwatch]
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  stage_name           = var.stage_name
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      method           = "$context.httpMethod"
      path             = "$context.resourcePath"
      status           = "$context.status"
      latencyMs        = "$context.responseLatency"
      integrationError = "$context.integration.error"
      integrationMs    = "$context.integration.latency"
      xrayTraceId      = "$context.xrayTraceId"
    })
  }

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = false # 메서드별 상세 메트릭 = 유료 커스텀 메트릭. 스테이지 기본 메트릭으로 충분
    logging_level          = "OFF" # 실행 로그는 보존기간 무제한 로그 그룹을 자동 생성 → 액세스 로그 + Lambda 로그로 대체
    throttling_rate_limit  = var.rate_limit
    throttling_burst_limit = var.burst_limit
  }
}

resource "aws_api_gateway_usage_plan" "this" {
  name = var.name

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  quota_settings {
    limit  = var.quota_per_month # 월 요청 상한 = 최악의 경우 API Gateway 요금의 상한
    period = "MONTH"
  }

  throttle_settings {
    rate_limit  = var.rate_limit
    burst_limit = var.burst_limit
  }
}

resource "aws_api_gateway_api_key" "this" {
  name = var.name
}

resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.this.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.function_name
  qualifier     = var.alias_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*/*"
}
