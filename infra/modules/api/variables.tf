variable "name" {
  type = string
}

variable "stage_name" {
  type    = string
  default = "v1"
}

variable "function_name" {
  type = string
}

variable "alias_name" {
  type = string
}

variable "alias_invoke_arn" {
  type = string
}

variable "rate_limit" {
  type = number
}

variable "burst_limit" {
  type = number
}

variable "quota_per_month" {
  type = number
}

variable "log_retention_days" {
  type = number
}

variable "boundary_arn" {
  type = string
}

variable "role_path" {
  type = string
}
