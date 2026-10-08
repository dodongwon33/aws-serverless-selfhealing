variable "project" {
  type    = string
  default = "selfheal"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "alert_email" {
  description = "알람/예산 알림 수신 메일. 공개 repo에 커밋하지 말고 TF_VAR_alert_email로 주입"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "powertools_layer_arn" {
  description = "Powertools for AWS Lambda (Python) 레이어. 버전 고정 — 최신 확인: aws ssm get-parameter --name /aws/service/powertools/python/x86_64/python3.12/latest"
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 10
}

variable "api_quota_per_month" {
  type    = number
  default = 50000
}

variable "api_rate_limit" {
  type    = number
  default = 5
}

variable "api_burst_limit" {
  type    = number
  default = 10
}

variable "log_retention_days" {
  type    = number
  default = 14
}
