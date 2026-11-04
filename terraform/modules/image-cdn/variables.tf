variable "name_prefix" {
  type = string
}

variable "bucket_name" {
  description = "이미지 버킷 이름 (전역 유일)"
  type        = string
}

variable "cors_allowed_origins" {
  description = "S3 CORS 허용 오리진 (프론트 도메인 등)"
  type        = list(string)
}

variable "price_class" {
  description = "PriceClass_200은 한국/아시아 엣지 포함, 남미/오세아니아 일부 제외"
  type        = string
  default     = "PriceClass_200"
}
