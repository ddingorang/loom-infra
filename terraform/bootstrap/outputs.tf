output "state_bucket_name" {
  description = "envs/prod/backend.hcl의 bucket 값으로 사용"
  value       = aws_s3_bucket.tfstate.id
}
