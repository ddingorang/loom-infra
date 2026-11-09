# 초기 설정

[← README로 돌아가기](../README.md)

## 전체 순서

```
1. terraform/  : AWS 리소스 생성 (ECR / S3 / CloudFront / Amplify / IAM)
                     → group_vars/infra_outputs.yml 자동 생성
2. IAM 액세스 키 발급 → vault.yml
3. 백엔드 이미지 ECR에 최초 push
4. ansible/    : server.yml (EC2 구성 + 백엔드 기동)
5. ansible/    : frontend-deploy.yml (Amplify 배포)
```

## 사전 준비

1. **EC2 인스턴스** (SSAFY 제공): Ubuntu 22.04 이상
   - 인바운드: 22(SSH), 80(HTTP), 443(HTTPS)
   - 8080(앱), 9090(Jenkins)은 Nginx 경유로만 접근하므로 열지 않습니다.
2. **Ansible 실행 환경** (Linux/macOS/WSL — Windows 네이티브는 컨트롤 노드 불가)
   ```bash
   pip install ansible
   ansible-galaxy collection install -r requirements.yml
   ```
3. **AWS CLI v2 + 계정 A 프로필** (frontend-deploy.yml용)
   ```bash
   aws configure --profile loom-main
   ```
4. **프론트 빌드 도구**: node/npm, zip
5. **SSH 키**: EC2 접속용 pem 키 (저장소에 넣지 마세요)

## 1단계: AWS 리소스 생성 (terraform/)

[terraform/ README](../../terraform/README.md)를 따라 `envs/prod`에서 `terraform apply`를 실행합니다.
apply가 끝나면 이 저장소의 `group_vars/infra_outputs.yml`이 자동으로 생성되고, ECR 주소, 버킷 이름,
CloudFront 도메인, Amplify 앱 ID가 여기에 들어갑니다. **이 값들은 all.yml에 직접 적지 않습니다.**

> 두 폴더가 `C:\SSAFY\terraform/`, `C:\SSAFY\ansible/`처럼 나란히 있다고 가정합니다.
> 위치가 다르면 terraform 변수 `ansible_outputs_path`를 바꾸세요.

## 2단계: 설정 파일 준비

| 템플릿 | 실제로 만들 파일 | 용도 |
|---|---|---|
| `inventory/hosts.ini.example` | `inventory/hosts.ini` | EC2 접속 정보 |
| `group_vars/all.yml.example` | `group_vars/all.yml` | 배포 설정값 |
| `group_vars/vault.yml.example` | `group_vars/vault.yml` | 비밀번호/키 (암호화 필수) |
| (Terraform이 생성) | `group_vars/infra_outputs.yml` | AWS 리소스 이름/ID |

```bash
cp inventory/hosts.ini.example inventory/hosts.ini
cp group_vars/all.yml.example  group_vars/all.yml
cp group_vars/vault.yml.example group_vars/vault.yml
```

`group_vars/all.yml`에서 채울 값:

- `db_host`, `db_name`, `db_user` — 계정 B RDS 접속 정보 ([RDS](RDS.md))
- `domain_name`, `certbot_email` — API 서버 도메인 (아래 HTTPS 참고)
- `frontend_src_dir` — 프론트 소스 경로 (기본값: `../../S15P31A104/frontend`)
- `extra_cors_origins` — Terraform의 `extra_cors_origins`와 같게

## 3단계: IAM 액세스 키 발급 → vault

Terraform은 사용자와 정책만 만들고 키는 만들지 않습니다(secret이 state에 남지 않도록).

```bash
aws iam create-access-key --user-name loom-ci  --profile loom-main   # ECR push/pull + Amplify 배포
aws iam create-access-key --user-name loom-app --profile loom-main   # S3 업로드 (Spring 컨테이너)
```

`group_vars/vault.yml`에 채운 뒤 암호화합니다.

```yaml
vault_db_password: ""             # 계정 B RDS 앱 사용자 비밀번호
vault_jwt_secret: ""              # openssl rand -base64 64
vault_verification_secret: ""     # openssl rand -base64 48 (32자 이상)
vault_redis_password: ""          # openssl rand -hex 24
vault_mail_username: ""           # 인증 메일 발신 Gmail 주소
vault_mail_password: ""           # Gmail 앱 비밀번호 (16자리)
vault_kakao_client_id: ""         # 소셜 로그인 (선택). 카카오 REST API 키
vault_kakao_client_secret: ""
vault_google_client_id: ""
vault_google_client_secret: ""
vault_naver_client_id: ""
vault_naver_client_secret: ""
vault_decart_api_key: ""          # 가상 착장 (선택). Decart API 키
vault_ecr_access_key_id: ""       # loom-ci
vault_ecr_secret_access_key: ""
vault_s3_access_key_id: ""        # loom-app
vault_s3_secret_access_key: ""
```

```bash
ansible-vault encrypt group_vars/vault.yml
```

소셜 로그인 키를 넣었다면 각 제공자 콘솔에 redirect URI `https://<프론트 도메인>/oauth/callback/{kakao|google|naver}`를 등록합니다 (글자까지 같아야 함).

`loom-ci` 키는 Jenkins 자격증명(`aws-ecr-credentials` 등)에도 같은 값으로 등록합니다.

## 4단계: ECR에 첫 이미지 push

> `--provenance=false --sbom=false`: 최신 Docker는 이미지에 출처 정보(attestation)를 묶어 index 형태로 push합니다.
> 이때 실제 이미지가 "태그 없는 항목"으로 따로 저장되어 ECR 정리 규칙(태그 없는 이미지 7일 후 삭제)에 지워지면
> `latest`를 pull할 수 없게 됩니다. 이 옵션으로 단일 이미지로만 push합니다. (Jenkins 빌드도 동일)

`server.yml`은 ECR에서 이미지를 pull하므로, 최초 실행 전에 백엔드 이미지가 하나는 있어야 합니다.
AI 서버 이미지는 없으면 자동으로 건너뛰고 백엔드만 배포되며, push한 뒤 `server.yml`을 다시 실행하면 추가됩니다.

```bash
ECR=$(terraform -chdir=../terraform/envs/prod output -raw ecr_repository_url)
aws ecr get-login-password --profile loom-main --region ap-northeast-2 \
  | docker login --username AWS --password-stdin ${ECR%%/*}
docker build --provenance=false --sbom=false -t $ECR:latest ../../S15P31A104/backend
docker push $ECR:latest

# AI 서버
AI_ECR=$(terraform -chdir=../terraform/envs/prod output -raw ai_ecr_repository_url)
docker build --provenance=false --sbom=false -t $AI_ECR:latest ../../S15P31A104/backend_ai
docker push $AI_ECR:latest
```

## HTTPS (API 서버)

프론트는 Amplify가 HTTPS로 서빙하므로, **API가 HTTP면 브라우저가 mixed content로 차단**합니다.
따라서 API 서버 도메인 + HTTPS는 사실상 필수입니다.

1. 도메인(예: `api.loom.example.com`)의 A 레코드를 EC2 퍼블릭 IP로 지정
2. `all.yml`에 설정
   ```yaml
   domain_name: api.loom.example.com
   certbot_email: you@example.com
   ```
3. `server.yml` 실행 시 certbot(webroot)으로 인증서를 발급하고 443을 설정합니다.
   이후 갱신은 certbot 타이머가 자동 처리하고, 갱신 시 Nginx를 리로드합니다.

`domain_name`은 `frontend_build_env.VITE_API_BASE_URL`에도 자동 반영됩니다.

다음 단계: [배포 실행/운영](OPERATIONS.md)
