variable "project_name" {
  type    = string
  default = "loom"
}

variable "aws_account_id" {
  description = "메인 계정(A) ID. 다른 계정 자격증명으로 실행하면 provider가 거부합니다."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로필 (~/.aws/credentials)"
  type        = string
  default     = "loom-main"
}

variable "state_bucket_name" {
  description = "state 저장용 버킷 이름 (전역 유일)"
  type        = string
}
