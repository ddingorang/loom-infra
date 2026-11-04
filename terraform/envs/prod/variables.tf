# --- 공통 ---
variable "project_name" {
  type    = string
  default = "loom"
}

variable "aws_account_id" {
  description = "메인 계정(A) ID"
  type        = string
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로필. 빈 값이면 환경변수 자격증명 사용 (CI 등)"
  type        = string
  default     = "loom-main"
}

# --- ECR ---
variable "ecr_repo_name" {
  type    = string
  default = "loom-backend"
}

variable "ai_ecr_repo_name" {
  type    = string
  default = "loom-ai"
}

# --- S3 + CloudFront ---
variable "image_bucket_name" {
  description = "이미지 버킷 이름 (전역 유일)"
  type        = string
}

# --- Amplify ---
variable "amplify_app_name" {
  type    = string
  default = "loom-frontend"
}

variable "amplify_branch" {
  type    = string
  default = "main"
}

# --- 도메인 (가비아 등록, Route 53 DNS) ---
variable "domain_name" {
  description = "루트 도메인. 프론트(Amplify)가 루트와 www를, API(EC2)가 api 서브도메인을 사용. 비우면 DNS/커스텀 도메인 미생성"
  type        = string
  default     = ""
}

variable "api_server_ip" {
  description = "api.<domain_name>이 가리킬 EC2 퍼블릭 IP (SSAFY 제공, Terraform 관리 대상 아님)"
  type        = string
  default     = ""
}

# --- CORS ---
variable "extra_cors_origins" {
  description = "Amplify 기본 도메인과 커스텀 도메인 외에 S3 CORS에 허용할 오리진 (로컬 개발 서버 등)"
  type        = list(string)
  default     = ["http://localhost:5173"]
}

# --- Ansible 연동 ---
variable "ansible_outputs_path" {
  description = "출력값을 기록할 Ansible vars 파일 경로. 빈 값이면 생성하지 않음"
  type        = string
  default     = "../../../ansible/group_vars/infra_outputs.yml"
}

# --- RDS 제어 (Mattermost /rds → Lambda → 계정 B RDS) ---
# db_account_id와 mattermost_channel_id를 모두 채우면 생성됩니다.
variable "db_account_id" {
  description = "RDS가 있는 계정(B) ID"
  type        = string
  default     = ""
}

variable "db_instance_identifier" {
  type    = string
  default = "loompostgres"
}

variable "rds_control_role_name" {
  description = "계정 B에 만드는 RDS 제어 역할 이름 (envs/db-account와 동일해야 함)"
  type        = string
  default     = "loom-rds-control"
}

variable "mattermost_channel_id" {
  description = "/rds 명령을 허용할 Mattermost 채널 ID"
  type        = string
  default     = ""
}
