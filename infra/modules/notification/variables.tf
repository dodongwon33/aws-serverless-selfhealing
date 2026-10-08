variable "name" {
  type = string
}

variable "alert_email" {
  type      = string
  sensitive = true
}
