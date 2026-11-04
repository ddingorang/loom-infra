# loom.ai.kr 호스팅 영역 (도메인 등록은 가비아, DNS는 Route 53)
# apply 후 출력되는 네임서버 4개를 가비아의 네임서버 설정에 입력해야 실제로 사용됩니다.
#
# 프론트 레코드(루트 ALIAS, www CNAME, 인증서 검증 CNAME)는 여기서 만들지 않습니다.
# 같은 계정에 이 영역이 있으면 Amplify 도메인 연결(modules/amplify)이 직접 만들고 관리합니다.
resource "aws_route53_zone" "this" {
  name    = var.domain_name
  comment = "loom - managed by terraform (frontend records managed by Amplify)"
}

# API 서버 (SSAFY 제공 EC2, Terraform 관리 대상 아님)
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.this.zone_id
  name    = "${var.api_subdomain}.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [var.api_ipv4]
}
