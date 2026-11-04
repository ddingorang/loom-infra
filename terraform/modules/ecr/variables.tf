variable "name" {
  description = "ECR 저장소 이름"
  type        = string
}

variable "max_image_count" {
  description = "보관할 최대 이미지 수"
  type        = number
  default     = 30
}
