module "ecr" {
  source = "../../modules/ecr"

  name = var.ecr_repo_name
}

# AI 서버(FastAPI) 이미지 — 백엔드와 같은 EC2의 compose 스택에서 실행
module "ecr_ai" {
  source = "../../modules/ecr"

  name = var.ai_ecr_repo_name
}

module "amplify" {
  source = "../../modules/amplify"

  app_name      = var.amplify_app_name
  branch_name   = var.amplify_branch
  custom_domain = var.domain_name

  # Route 53 영역이 먼저 있어야 Amplify가 도메인 레코드를 그 영역에 자동으로 만듭니다
  depends_on = [module.dns]
}

# loom.ai.kr 영역 + api → EC2. 루트·www 레코드는 Amplify가 이 영역에 직접 만듦
module "dns" {
  source = "../../modules/dns"
  count  = var.domain_name != "" ? 1 : 0

  domain_name = var.domain_name
  api_ipv4    = var.api_server_ip
}

locals {
  # 프론트가 실제로 서비스되는 오리진 (S3 CORS / 백엔드 CORS 허용 대상)
  frontend_origins = concat(
    [module.amplify.branch_url],
    var.domain_name != "" ? ["https://${var.domain_name}"] : [],
  )
}

module "image_cdn" {
  source = "../../modules/image-cdn"

  name_prefix = var.project_name
  bucket_name = var.image_bucket_name
  # 프론트에서 presigned URL로 직접 업로드할 수 있도록 Amplify 기본·커스텀 도메인 자동 포함
  cors_allowed_origins = concat(local.frontend_origins, var.extra_cors_origins)
}

module "iam" {
  source = "../../modules/iam"

  name_prefix         = var.project_name
  ecr_repository_arns = [module.ecr.repository_arn, module.ecr_ai.repository_arn]
  amplify_app_arn     = module.amplify.app_arn
  image_bucket_arn    = module.image_cdn.bucket_arn
}

module "rds_control" {
  source = "../../modules/rds-control"
  count  = var.db_account_id != "" && var.mattermost_channel_id != "" ? 1 : 0

  db_instance_identifier = var.db_instance_identifier
  db_region              = var.aws_region
  target_role_arn        = "arn:aws:iam::${var.db_account_id}:role/${var.rds_control_role_name}"
  allowed_channel_id     = var.mattermost_channel_id
}
