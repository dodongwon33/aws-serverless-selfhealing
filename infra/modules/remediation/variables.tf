variable "name" {
  type = string
}

variable "ssm_prefix" {
  type = string
}

variable "source_dir" {
  type = string
}

variable "function_name" {
  type = string
}

variable "function_arn" {
  type = string
}

variable "alias_name" {
  type = string
}

variable "initial_version" {
  type = string
}

variable "alarm_names" {
  type = list(string)
}

variable "codedeploy_app" {
  type = string
}

variable "codedeploy_group" {
  type = string
}

variable "alerts_topic_arn" {
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
