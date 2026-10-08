variable "project" {
  type    = string
  default = "selfheal"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "github_repo" {
  description = "owner/repo — OIDC 신뢰 정책의 sub 클레임 범위"
  type        = string
}

variable "create_oidc_provider" {
  description = "계정에 GitHub OIDC Provider가 이미 있으면 false (URL당 1개만 생성 가능)"
  type        = bool
  default     = true
}
