variable "name_prefix" {
  type = string
}

variable "ecr_repository_arns" {
  description = "push/pull을 허용할 ECR 저장소 ARN 목록 (backend, ai)"
  type        = list(string)
}

variable "amplify_app_arn" {
  type = string
}

variable "image_bucket_arn" {
  type = string
}
