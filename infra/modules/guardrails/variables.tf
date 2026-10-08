variable "name" {
  type = string
}

variable "monthly_budget_usd" {
  type = number
}

variable "alert_email" {
  type      = string
  sensitive = true
}

variable "rest_api_id" {
  type = string
}

variable "stage_name" {
  type = string
}

variable "freeze_param_name" {
  type = string
}

variable "freeze_param_arn" {
  type = string
}

variable "alerts_topic_arn" {
  type = string
}

variable "source_dir" {
  type = string
}

variable "boundary_arn" {
  type = string
}

variable "role_path" {
  type = string
}

variable "log_retention_days" {
  type = number
}
