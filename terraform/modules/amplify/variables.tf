variable "app_name" {
  type = string
}

variable "branch_name" {
  type    = string
  default = "main"
}

variable "custom_domain" {
  description = "프론트 커스텀 도메인 (예: loom.ai.kr). 비우면 Amplify 기본 도메인만 사용"
  type        = string
  default     = ""
}
