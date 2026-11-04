terraform {
  # 1.10+: S3 backend의 use_lockfile(네이티브 잠금) 지원 → DynamoDB 잠금 테이블 불필요
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
