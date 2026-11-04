variable "function_name" {
  type    = string
  default = "loom-rds-control"
}

variable "db_instance_identifier" {
  description = "제어할 RDS 인스턴스 식별자 (계정 B)"
  type        = string
}

variable "db_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "target_role_arn" {
  description = "계정 B에 만든 RDS 제어 역할 ARN (envs/db-account)"
  type        = string
}

variable "allowed_channel_id" {
  description = "/rds 명령을 허용할 Mattermost 채널 ID"
  type        = string
}

variable "token_param_name" {
  description = "Mattermost 슬래시 커맨드 토큰을 담은 SSM SecureString 이름"
  type        = string
  default     = "/loom/rds-control/mattermost-token"
}

variable "webhook_param_name" {
  description = "Mattermost Incoming Webhook URL을 담은 SSM SecureString 이름"
  type        = string
  default     = "/loom/rds-control/mattermost-webhook-url"
}
