output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ai_ecr_repository_url" {
  value = module.ecr_ai.repository_url
}

output "image_bucket_name" {
  value = module.image_cdn.bucket_name
}

output "cloudfront_distribution_id" {
  value = module.image_cdn.distribution_id
}

output "cloudfront_domain_name" {
  value = module.image_cdn.distribution_domain_name
}

output "amplify_app_id" {
  value = module.amplify.app_id
}

output "amplify_branch_url" {
  value = module.amplify.branch_url
}

output "frontend_url" {
  value = coalesce(module.amplify.custom_domain_url, module.amplify.branch_url)
}

output "api_domain" {
  value = one(module.dns[*].api_fqdn)
}

output "route53_name_servers" {
  description = "가비아 → 도메인 관리 → 네임서버 설정에 이 4개를 입력"
  value       = one(module.dns[*].name_servers)
}

output "iam_users" {
  description = "apply 후 액세스 키를 발급할 사용자 (aws iam create-access-key --user-name <이름>)"
  value = {
    ci  = module.iam.ci_user_name
    app = module.iam.app_user_name
  }
}

output "rds_control_function_url" {
  description = "Mattermost 슬래시 커맨드 Request URL"
  value       = one(module.rds_control[*].function_url)
}

output "rds_control_lambda_role_arn" {
  description = "envs/db-account의 lambda_role_arn 값"
  value       = one(module.rds_control[*].lambda_role_arn)
}
