variable "domain_name" {
  description = "루트 도메인 (예: loom.ai.kr)"
  type        = string
}

variable "api_subdomain" {
  type    = string
  default = "api"
}

variable "api_ipv4" {
  description = "API 서버(EC2) 퍼블릭 IP"
  type        = string
}
