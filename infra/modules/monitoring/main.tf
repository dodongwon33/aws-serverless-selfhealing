# 알람 메트릭 5개 (CloudWatch 무료 10개 이내), 대시보드 1개 (무료 3개 이내), 커스텀 메트릭 0개

locals {
  api_dims    = { ApiName = var.api_name, Stage = var.stage_name }
  alias_dims  = { FunctionName = var.function_name, Resource = "${var.function_name}:${var.alias_name}" }
  alarm_5xx   = "${var.name}-api-5xx-rate"
  alarm_error = "${var.name}-lambda-errors"
}

# 1) API 5xx 비율 > 5% (3분 연속). 분당 요청 20건 미만이면 0으로 처리해 저트래픽 오탐 방지
resource "aws_cloudwatch_metric_alarm" "api_5xx_rate" {
  alarm_name          = local.alarm_5xx
  alarm_description   = "API 5xx rate > 5% for 3 consecutive minutes → auto rollback"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  metric_query {
    id          = "rate"
    expression  = "IF(requests >= 20, 100 * errors / requests, 0)"
    label       = "5xx rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      dimensions  = local.api_dims
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions  = local.api_dims
      period      = 60
      stat        = "Sum"
    }
  }
}

# 2) alias 기준 Lambda 처리되지 않은 예외 (분당 3건 이상, 2분 연속)
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = local.alarm_error
  alarm_description   = "Lambda unhandled errors on alias → auto rollback"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = local.alias_dims
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]
}

# 3) 지연시간 p99 > 3초 — 원인이 다양해 자동조치보다 알림이 현실적
resource "aws_cloudwatch_metric_alarm" "api_latency_p99" {
  alarm_name          = "${var.name}-api-latency-p99"
  alarm_description   = "API p99 latency > 3s (notify only)"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = local.api_dims
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
}

# 4) Lambda 동시성 쓰로틀 — 알림만
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.name}-lambda-throttles"
  alarm_description   = "Lambda throttles (notify only)"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = local.alias_dims
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alerts_topic_arn]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "alarm", x = 0, y = 0, width = 24, height = 3
        properties = {
          title  = "Alarms"
          alarms = [for a in [aws_cloudwatch_metric_alarm.api_5xx_rate, aws_cloudwatch_metric_alarm.lambda_errors, aws_cloudwatch_metric_alarm.api_latency_p99, aws_cloudwatch_metric_alarm.lambda_throttles] : a.arn]
        }
      },
      {
        type = "metric", x = 0, y = 3, width = 12, height = 6
        properties = {
          title = "API requests / 4xx / 5xx", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_name, "Stage", var.stage_name],
            [".", "4XXError", ".", ".", ".", "."],
            [".", "5XXError", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 3, width = 12, height = 6
        properties = {
          title = "API latency p50 / p99 (ms)", region = var.region, period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiName", var.api_name, "Stage", var.stage_name, { stat = "p50" }],
            ["...", { stat = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 9, width = 12, height = 6
        properties = {
          title = "Lambda (alias live) invocations / errors / throttles", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.function_name, "Resource", "${var.function_name}:${var.alias_name}"],
            [".", "Errors", ".", ".", ".", "."],
            [".", "Throttles", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 9, width = 12, height = 6
        properties = {
          title = "DynamoDB consumed capacity / throttled", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.table_name],
            [".", "ConsumedWriteCapacityUnits", ".", "."],
            [".", "ThrottledRequests", ".", ".", "Operation", "PutItem"],
          ]
        }
      },
    ]
  })
}

# Logs Insights 저장 쿼리 (무료, 스캔한 GB만 과금)
resource "aws_cloudwatch_query_definition" "errors_by_version" {
  name            = "${var.name}/lambda-errors-by-version"
  log_group_names = [var.lambda_log_group_name]
  query_string    = <<-EOT
    fields @timestamp, level, message, function_request_id, xray_trace_id
    | filter level = "ERROR" or @message like /Task timed out|injected fault/
    | parse @logStream /\[(?<version>[^\]]+)\]/
    | stats count() as errors by version, bin(1m)
  EOT
}

resource "aws_cloudwatch_query_definition" "slow_requests" {
  name            = "${var.name}/api-slow-requests"
  log_group_names = [var.access_log_group_name]
  query_string    = <<-EOT
    fields @timestamp, method, path, status, latencyMs, integrationMs, xrayTraceId
    | filter latencyMs > 1000 or status >= 500
    | sort latencyMs desc
    | limit 50
  EOT
}
