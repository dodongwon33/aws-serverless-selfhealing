variable "name" {
  type = string
}

variable "source_dir" {
  type = string
}

variable "table_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "layer_arns" {
  type    = list(string)
  default = []
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

variable "memory_size" {
  type    = number
  default = 256
}

variable "timeout" {
  type    = number
  default = 10
}
