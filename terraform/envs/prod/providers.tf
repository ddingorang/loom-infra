# 메인 계정(A)만 관리합니다.
# RDS 계정(B)과 SSAFY 제공 EC2는 이미 구성되어 있어 Terraform 관리 대상이 아닙니다.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  # 다른 계정(예: RDS 계정 B) 자격증명으로 실행하면 plan 단계에서 바로 거부됩니다.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}
