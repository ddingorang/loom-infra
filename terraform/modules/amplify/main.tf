# Git 저장소를 연결하지 않은 앱 → zip 수동 배포(create-deployment) 전용
# (lab.ssafy.com 자체 호스팅 GitLab은 Amplify Git 연동 미지원)
resource "aws_amplify_app" "this" {
  name     = var.app_name
  platform = "WEB"

  # 커스텀 도메인 사용 시 www → 루트 리다이렉트. 규칙은 위에서부터 적용되므로 SPA 규칙보다 먼저 둡니다.
  dynamic "custom_rule" {
    for_each = var.custom_domain != "" ? [var.custom_domain] : []
    content {
      source = "https://www.${custom_rule.value}"
      target = "https://${custom_rule.value}"
      status = "301"
    }
  }

  # SPA(React Router) 새로고침/직접 진입 시 404 대신 index.html 반환
  custom_rule {
    source = "</^[^.]+$|\\.(?!(css|gif|ico|jpg|jpeg|js|png|txt|svg|woff|woff2|ttf|map|json|webp|avif)$)([^.]+$)/>"
    target = "/index.html"
    status = "200"
  }
}

resource "aws_amplify_branch" "this" {
  app_id            = aws_amplify_app.this.id
  branch_name       = var.branch_name
  stage             = "PRODUCTION"
  enable_auto_build = false
}

# 커스텀 도메인 (루트 + www). 인증서는 Amplify가 발급·갱신합니다.
# 같은 계정에 Route 53 영역(modules/dns)이 있으면 Amplify가 검증용 CNAME과 도메인 레코드를 직접 만듭니다.
# 네임서버 이전 전에는 검증이 끝나지 않으므로 apply가 기다리지 않게 합니다.
resource "aws_amplify_domain_association" "this" {
  count = var.custom_domain != "" ? 1 : 0

  app_id                = aws_amplify_app.this.id
  domain_name           = var.custom_domain
  wait_for_verification = false

  sub_domain {
    branch_name = aws_amplify_branch.this.branch_name
    prefix      = ""
  }

  sub_domain {
    branch_name = aws_amplify_branch.this.branch_name
    prefix      = "www"
  }
}
