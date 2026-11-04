output "function_url" {
  description = "Mattermost 슬래시 커맨드의 Request URL"
  value       = aws_lambda_function_url.this.function_url
}

output "lambda_role_arn" {
  description = "계정 B 역할의 신뢰 정책에 넣을 Lambda 실행 역할 ARN"
  value       = aws_iam_role.lambda.arn
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}
