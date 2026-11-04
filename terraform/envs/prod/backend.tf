# state는 bootstrap/에서 만든 S3 버킷에 저장합니다.
# 버킷 이름/프로필은 커밋하지 않는 backend.hcl로 주입합니다 (partial configuration).
#
#   cp backend.hcl.example backend.hcl
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "loom/prod/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
