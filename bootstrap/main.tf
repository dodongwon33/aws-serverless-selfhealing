# 1회성 로컬 apply 스택 (local state).
# 원격 state가 저장될 버킷 자체는 원격 state에 둘 수 없으므로(닭과 달걀) 분리한다.

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  r            = var.region
  a            = local.account_id
  p            = var.project
  state_bucket = "${var.project}-tfstate-${local.account_id}"
  boundary_arn = "arn:aws:iam::${local.a}:policy/${local.p}-workload-boundary"
  oidc_arn     = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# ---------- Terraform state: S3 (버전관리 + S3 네이티브 락, DynamoDB 락 테이블 불필요) ----------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3: 무료 (KMS CMK는 월 $1)
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

# ---------- GitHub OIDC (장기 Access Key 미사용) ----------

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust_main" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "trust_pr" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

# ---------- 권한 경계: Terraform이 만드는 모든 워크로드 역할의 상한선 ----------
# 배포 역할이 IAM 역할을 만들 수 있으면 "관리자 역할을 만들어 탈취"하는 권한 상승 경로가 생긴다.
# 배포 역할은 이 경계가 붙은 역할만 생성/수정할 수 있다.

data "aws_iam_policy_document" "boundary" {
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
      "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents",
    ]
    resources = ["*"]
  }
  statement {
    sid = "XRay"
    actions = [
      "xray:PutTraceSegments", "xray:PutTelemetryRecords",
      "xray:GetSamplingRules", "xray:GetSamplingTargets", "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "DynamoDB"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:DescribeTable"]
    resources = ["arn:aws:dynamodb:${local.r}:${local.a}:table/${local.p}-*"]
  }
  statement {
    sid = "LambdaAlias"
    actions = [
      "lambda:GetAlias", "lambda:UpdateAlias", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
      "lambda:ListVersionsByFunction", "lambda:InvokeFunction", "lambda:GetProvisionedConcurrencyConfig",
    ]
    resources = ["arn:aws:lambda:${local.r}:${local.a}:function:${local.p}-*"]
  }
  statement {
    sid       = "Ssm"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:${local.r}:${local.a}:parameter/${local.p}/*"]
  }
  statement {
    sid       = "Sns"
    actions   = ["sns:Publish"]
    resources = ["arn:aws:sns:${local.r}:${local.a}:${local.p}-*"]
  }
  statement {
    sid       = "ReadOnlyOps"
    actions   = ["codedeploy:ListDeployments", "codedeploy:GetDeployment", "cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGatewayStage"
    actions   = ["apigateway:GET", "apigateway:PATCH"]
    resources = ["arn:aws:apigateway:${local.r}::/restapis/*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name   = "${local.p}-workload-boundary"
  policy = data.aws_iam_policy_document.boundary.json
}

# ---------- 배포 역할 (main 브랜치 전용) ----------

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "TfStateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "TfStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "Lambda"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:${local.r}:${local.a}:function:${local.p}-*"]
  }
  statement {
    sid       = "LambdaGlobal"
    actions   = ["lambda:GetLayerVersion", "lambda:ListFunctions", "lambda:GetAccountSettings"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGateway" # API Gateway ARN은 이름이 아닌 랜덤 ID라 이름 기반 스코프가 불가 → 리전으로 한정
    actions   = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
    resources = ["arn:aws:apigateway:${local.r}::/*"]
  }
  statement {
    sid       = "DynamoDB"
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:${local.r}:${local.a}:table/${local.p}-*"]
  }
  statement {
    sid     = "Logs"
    actions = ["logs:*"]
    resources = [
      "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/lambda/${local.p}-*",
      "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/lambda/${local.p}-*:*",
      "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/apigateway/${local.p}-*",
      "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/apigateway/${local.p}-*:*",
    ]
  }
  statement {
    sid       = "LogsGlobal"
    actions   = ["logs:DescribeLogGroups", "logs:PutQueryDefinition", "logs:DeleteQueryDefinition", "logs:DescribeQueryDefinitions"]
    resources = ["*"]
  }
  statement {
    sid = "CloudWatch"
    actions = [
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource", "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
    ]
    resources = [
      "arn:aws:cloudwatch:${local.r}:${local.a}:alarm:${local.p}-*",
      "arn:aws:cloudwatch::${local.a}:dashboard/${local.p}-*",
    ]
  }
  statement {
    sid       = "CloudWatchRead"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:GetDashboard", "cloudwatch:ListDashboards"]
    resources = ["*"]
  }
  statement {
    sid       = "Events"
    actions   = ["events:*"]
    resources = ["arn:aws:events:${local.r}:${local.a}:rule/${local.p}-*"]
  }
  statement {
    sid       = "Sns"
    actions   = ["sns:*"]
    resources = ["arn:aws:sns:${local.r}:${local.a}:${local.p}-*"]
  }
  statement {
    sid = "Ssm"
    actions = [
      "ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter", "ssm:DeleteParameter",
      "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource",
    ]
    resources = ["arn:aws:ssm:${local.r}:${local.a}:parameter/${local.p}/*"]
  }
  statement {
    sid       = "SsmDescribe"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid     = "CodeDeploy"
    actions = ["codedeploy:*"]
    resources = [
      "arn:aws:codedeploy:${local.r}:${local.a}:application:${local.p}-*",
      "arn:aws:codedeploy:${local.r}:${local.a}:deploymentgroup:${local.p}-*/*",
      "arn:aws:codedeploy:${local.r}:${local.a}:deploymentconfig:*",
    ]
  }
  statement {
    sid       = "Budgets"
    actions   = ["budgets:ViewBudget", "budgets:ModifyBudget", "budgets:ListTagsForResource", "budgets:TagResource", "budgets:UntagResource"]
    resources = ["arn:aws:budgets::${local.a}:budget/${local.p}-*"]
  }
  statement {
    sid = "IamRead"
    actions = [
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:ListRoleTags", "iam:GetPolicy", "iam:GetPolicyVersion",
    ]
    resources = ["*"]
  }
  # 워크로드 역할은 path=/<project>/ 아래에만 존재 → bootstrap 역할(path=/)은 건드릴 수 없다.
  statement {
    sid = "IamWriteOnlyWithBoundary"
    actions = [
      "iam:CreateRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.a}:role/${local.p}/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }
  statement {
    sid       = "IamManage"
    actions   = ["iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy"]
    resources = ["arn:aws:iam::${local.a}:role/${local.p}/*"]
  }
  statement {
    sid       = "PassWorkloadRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.a}:role/${local.p}/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "codedeploy.amazonaws.com", "apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.p}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust_main.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# ---------- Plan 역할 (PR 전용, 읽기 전용) ----------

resource "aws_iam_role" "plan" {
  name                 = "${local.p}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust_pr.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
