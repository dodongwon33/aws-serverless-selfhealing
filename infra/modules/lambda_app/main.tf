# 비즈니스 API Lambda + alias `live`.
# 코드는 CI(CodeDeploy 카나리)가 소유하고, Terraform은 함수 설정만 소유한다.
# 그래서 code/alias 버전은 ignore_changes — 둘이 같은 리소스를 두고 싸우지 않게 한다.

data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${var.name}.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  path                 = var.role_path
  permissions_boundary = var.boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "this" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
  statement {
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [var.table_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "app"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  role             = aws_iam_role.this.arn
  runtime          = "python3.12"
  handler          = "app.lambda_handler"
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  memory_size      = var.memory_size
  timeout          = var.timeout
  layers           = var.layer_arns
  publish          = true

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      TABLE_NAME              = var.table_name
      POWERTOOLS_SERVICE_NAME = var.name
      POWERTOOLS_LOG_LEVEL    = "INFO"
      FAULT_RATE              = "0"
      FAULT_LATENCY_MS        = "0"
    }
  }

  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy.this]

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}
