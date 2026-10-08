variable "name" {
  type = string
}

variable "source_dir" {
  type = string
}

variable "handler" {
  type = string
}

variable "policy_json" {
  type = string
}

variable "environment" {
  type = map(string)
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

variable "timeout" {
  type    = number
  default = 30
}
