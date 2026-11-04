output "ci_user_name" {
  value = aws_iam_user.ci.name
}

output "app_user_name" {
  value = aws_iam_user.app.name
}
