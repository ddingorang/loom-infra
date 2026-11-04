output "app_id" {
  value = aws_amplify_app.this.id
}

output "app_arn" {
  value = aws_amplify_app.this.arn
}

output "default_domain" {
  value = aws_amplify_app.this.default_domain
}

output "branch_url" {
  value = "https://${aws_amplify_branch.this.branch_name}.${aws_amplify_app.this.default_domain}"
}

output "custom_domain_url" {
  value = one([for d in aws_amplify_domain_association.this : "https://${d.domain_name}"])
}
