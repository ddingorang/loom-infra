# apply 결과를 Ansible이 읽는 vars 파일로 기록합니다.
# `ansible/`의 server.yml / frontend-deploy.yml이 infra_outputs.* 로 참조합니다.
# (키 이름을 바꾸면 ansible/group_vars/all.yml도 같이 바꿔야 합니다)
locals {
  ansible_infra_outputs = {
    infra_outputs = {
      EcrRepositoryUri         = module.ecr.repository_url
      AiEcrRepositoryUri       = module.ecr_ai.repository_url
      ImageBucketName          = module.image_cdn.bucket_name
      CloudFrontDistributionId = module.image_cdn.distribution_id
      CloudFrontDomainName     = module.image_cdn.distribution_domain_name
      AmplifyAppId             = module.amplify.app_id
      AmplifyBranchUrl         = module.amplify.branch_url
      # 커스텀 도메인이 있으면 그 주소, 없으면 Amplify 기본 주소
      FrontendUrl     = coalesce(module.amplify.custom_domain_url, module.amplify.branch_url)
      FrontendOrigins = local.frontend_origins
      ApiDomain       = one(module.dns[*].api_fqdn)
    }
  }
}

resource "local_file" "ansible_infra_outputs" {
  count = var.ansible_outputs_path != "" ? 1 : 0

  filename        = "${path.root}/${var.ansible_outputs_path}"
  file_permission = "0644"
  content = join("", [
    "# terraform/(envs/prod)이 자동 생성한 파일입니다. 직접 수정하지 마세요. (커밋 안 됨)\n",
    yamlencode(local.ansible_infra_outputs),
  ])
}
