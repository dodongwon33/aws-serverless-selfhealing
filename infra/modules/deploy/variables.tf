variable "name" {
  type = string
}

variable "deployment_group_name" {
  type = string
}

variable "deployment_config_name" {
  type    = string
  default = "CodeDeployDefault.LambdaCanary10Percent5Minutes"
}

variable "alarm_names" {
  type = list(string)
}

variable "boundary_arn" {
  type = string
}

variable "role_path" {
  type = string
}
