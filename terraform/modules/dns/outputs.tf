output "name_servers" {
  description = "가비아 네임서버 설정에 입력할 값"
  value       = aws_route53_zone.this.name_servers
}

output "api_fqdn" {
  value = aws_route53_record.api.fqdn
}
