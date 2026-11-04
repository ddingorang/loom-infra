# RDS가 있는 계정(B)에 RDS 제어 역할 하나만 만듭니다.
# 계정 A의 rds-control Lambda만 이 역할로 전환할 수 있고, 지정한 인스턴스의 시작/중지/조회만 허용합니다.
#
# 계정 B 자격증명(loom-db 프로필)으로 실행하며, 리소스가 역할 하나뿐이라 state는 로컬에 둡니다.
# (콘솔로 직접 만들 경우 README의 정책 JSON 참고)
#
# 순서: envs/prod apply(Lambda 역할 생성) → 여기 apply (신뢰 정책이 Lambda 역할 ARN을 참조하므로)
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = [var.db_account_id]

  default_tags {
    tags = {
      Project   = "loom"
      ManagedBy = "terraform"
    }
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.lambda_role_arn]
    }
  }
}

resource "aws_iam_role" "rds_control" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "rds_control" {
  statement {
    actions = [
      "rds:DescribeDBInstances",
      "rds:StartDBInstance",
      "rds:StopDBInstance",
    ]
    resources = ["arn:aws:rds:${var.aws_region}:${var.db_account_id}:db:${var.db_instance_identifier}"]
  }
}

resource "aws_iam_role_policy" "rds_control" {
  name   = "rds-start-stop"
  role   = aws_iam_role.rds_control.id
  policy = data.aws_iam_policy_document.rds_control.json
}

output "role_arn" {
  value = aws_iam_role.rds_control.arn
}
