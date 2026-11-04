variable "db_account_id" {
  description = "RDS가 있는 계정(B) ID. 다른 계정 자격증명으로 실행하면 거부됩니다."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "계정 B AWS CLI 프로필"
  type        = string
  default     = "loom-db"
}

variable "db_instance_identifier" {
  type    = string
  default = "loompostgres"
}

variable "role_name" {
  description = "envs/prod의 rds_control_role_name과 같아야 함"
  type        = string
  default     = "loom-rds-control"
}

variable "lambda_role_arn" {
  description = "계정 A rds-control Lambda 실행 역할 ARN (envs/prod 출력 rds_control_lambda_role_arn)"
  type        = string
}
