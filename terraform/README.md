# terraform/

Loom 서비스의 **AWS 리소스**를 코드로 관리합니다.
서버 설정과 애플리케이션 배포는 [ansible/](../ansible)이 맡고, 이 폴더는 "무엇이 존재하는가"만 책임집니다.

<br>

## 설계 컨셉

| 원칙 | 내용 |
|---|---|
| **역할 분리** | Terraform = 클라우드 리소스(무엇이 있는가), Ansible = 서버 구성 · 배포(어떻게 돌리는가). 두 도구가 같은 대상을 건드리지 않습니다 |
| **출력은 자동 전달** | apply 결과(ECR 주소, 버킷, CloudFront, Amplify ID, 도메인)를 `ansible/group_vars/infra_outputs.yml`로 자동 기록합니다. 사람이 값을 옮겨 적지 않습니다 |
| **비밀은 state 밖** | IAM 액세스 키, Mattermost 토큰 같은 비밀값은 Terraform으로 만들지 않습니다. 수동 발급 · SSM 직접 입력으로 state 파일에 남지 않게 합니다 |
| **계정 경계 강제** | `allowed_account_ids`로 다른 계정 자격증명은 plan 단계에서 거부됩니다. 계정 B(RDS)에는 최소 권한 역할 하나만 둡니다 |
| **주어진 것은 관리하지 않음** | SSAFY가 제공한 EC2와 이미 구성된 RDS는 import하지 않습니다. 소유하지 않은 리소스를 코드로 덮어쓰지 않기 위함입니다 |
| **지우면 안 되는 것은 잠금** | 이미지 버킷과 state 버킷은 `prevent_destroy`. 실수로 `destroy`해도 막힙니다 |

<br>

## 전체 구성

```
                     ┌──────────────── AWS 계정 A (main account) · Terraform 관리 ────────────────┐
                     │                                                                           │
 loom.ai.kr ─────────┼─> Route 53 ─> Amplify Hosting (React 정적 파일, 인증서 Amplify 관리)       │
 www.loom.ai.kr ─────┼─>             └ www → 루트 301                                            │
                     │                                                                           │
 dxxxx.cloudfront.net┼─> CloudFront ─(OAC)─> S3 이미지 버킷 (비공개)                              │
                     │                                                                           │
                     │  ECR loom-backend · loom-ai   ◀─ Jenkins push (IAM loom-ci)               │
                     │  IAM loom-ci (ECR · Amplify 배포) / loom-app (S3 업로드)                   │
                     │  Lambda loom-rds-control      ◀─ Mattermost /rds                          │
                     └──────────────────────────────│────────────────────────────────────────────┘
 api.loom.ai.kr ─> Route 53 A ─> EC2 x.xx.xx.xx     │ AssumeRole
                   (SSAFY 제공 · 구성은 ansible/)     │
                     ┌──────────────────────────────▼──── AWS 계정 B (RDS account)  ─────┐
                     │  IAM 역할 loom-rds-control (RDS 시작 · 중지 · 조회만)                │
                     │  RDS PostgreSQL loompostgres (Terraform 관리 밖)                     │
                     └────────────────────────────────────────────────────────────────────┘
```

| 관리함 | 관리하지 않음 |
|---|---|
| ECR `loom-backend`, `loom-ai` + 보관 정책 | EC2 (SSAFY 제공) |
| S3 이미지 버킷 + CloudFront(OAC) | RDS · 보안그룹 (계정 B에 이미 구성) |
| Amplify 앱 · 브랜치 · 커스텀 도메인 | 서버 설정 · 컨테이너 배포 → ansible/ |
| Route 53 `loom.ai.kr` 영역 + `api` 레코드 | IAM 액세스 키 · SSM 비밀값 (수동) |
| IAM 사용자 `loom-ci`, `loom-app` | |
| RDS 제어 Lambda (Mattermost `/rds`) | |
| 계정 B: RDS 제어 역할 1개 (`envs/db-account`) | |

<br>

## 디렉토리

```
terraform/
├── bootstrap/                  # state 저장용 S3 버킷 (최초 1회, 로컬 state)
├── envs/
│   ├── prod/                   # 계정 A 메인 리소스 (S3 원격 state)
│   │   ├── versions.tf         # Terraform >= 1.10, AWS ~> 6.0
│   │   ├── backend.tf          # S3 backend + use_lockfile (DynamoDB 불필요)
│   │   ├── providers.tf        # allowed_account_ids, 공통 태그
│   │   ├── main.tf             # 모듈 조합
│   │   ├── variables.tf · outputs.tf
│   │   └── ansible_handoff.tf  # → ansible/group_vars/infra_outputs.yml
│   └── db-account/             # 계정 B: RDS 제어 역할 1개 (로컬 state)
└── modules/
    ├── ecr/                    # 저장소 + 수명 주기 (태그 없는 이미지 7일, 최근 30개 보관)
    ├── image-cdn/              # S3(비공개 · 암호화) + OAC + CloudFront + CORS
    ├── amplify/                # 앱 · 브랜치 · 커스텀 도메인 · www 301 · SPA rewrite
    ├── dns/                    # Route 53 영역 + api A 레코드
    ├── iam/                    # loom-ci · loom-app 사용자와 최소 권한 정책
    └── rds-control/            # Lambda(Python) + Function URL + 단위 테스트
```

<br>

## 모듈별 설계 메모

**ECR** — Jenkins가 커밋 해시와 `latest` 태그로 push합니다. 롤백은 커밋 해시로 다시 배포하므로 최근 30개를 남깁니다.

**image-cdn** — 버킷은 완전 비공개, 읽기는 CloudFront OAC로만 허용합니다. 업로드는 Spring이 `loom-app` 키로 하거나 프론트가 presigned URL로 직접 올리므로, 버킷 CORS에 프론트 출처(Amplify 기본 주소 · `loom.ai.kr` · `extra_cors_origins`)를 자동으로 넣습니다.

**amplify** — `lab.ssafy.com`(자체 호스팅 GitLab)은 Amplify Git 연동을 지원하지 않아 **Git 연결 없이 zip 수동 배포** 방식입니다. Jenkins가 빌드한 결과를 `create-deployment`로 올립니다. 같은 계정에 Route 53 영역이 있어서 루트 · www · 인증서 검증 레코드는 Amplify가 직접 만듭니다.

**dns** — 도메인 등록은 가비아, 네임서버는 Route 53입니다. Terraform은 영역과 `api` A 레코드만 만듭니다. 루트 · www 레코드를 Terraform에도 적으면 Amplify와 충돌("already exists")합니다.

**iam** — 사용자를 용도별로 둘로 나눴습니다. `loom-ci`(ECR push/pull, Amplify 배포)는 Jenkins와 서버의 ECR 로그인에, `loom-app`(이미지 버킷 읽기 · 쓰기)은 Spring 컨테이너에 씁니다. 키가 유출돼도 피해 범위가 용도 안으로 제한됩니다.

**rds-control** — 개발 기간에 RDS를 쓸 때만 켜서 비용을 줄이는 장치입니다. 계정이 나뉘어 있어 Lambda는 계정 A에 두고 계정 B 역할을 AssumeRole합니다. 그 역할은 RDS 시작 · 중지 · 조회만 할 수 있고 삭제 권한은 없습니다.

<br>

## 시작하기

**준비:** Terraform 1.10+ (`winget install Hashicorp.Terraform`), AWS CLI 프로필 `loom-main`(계정 A)

```bash
# 1) state 버킷 (최초 1회)
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply

# 2) 메인 리소스
cd ../envs/prod
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan
terraform apply          # → ../../../ansible/group_vars/infra_outputs.yml 생성

# 3) IAM 액세스 키 (수동 발급, state에 남기지 않음)
aws iam create-access-key --user-name loom-ci  --profile loom-main   # → Jenkins aws-loom-ci + Ansible vault
aws iam create-access-key --user-name loom-app --profile loom-main   # → Ansible vault (Spring S3 업로드)
```

이후 서버 구성은 [ansible/ 초기 설정](../ansible/docs/SETUP.md)으로 이어집니다.
Windows에서 `terraform`을 못 찾으면 winget 설치 경로(`%LOCALAPPDATA%\Microsoft\WinGet\Packages\Hashicorp.Terraform_…\terraform.exe`)로 실행하세요.

<br>

## 주요 변수 (`envs/prod/terraform.tfvars`)

| 변수 | 설명 |
|---|---|
| `aws_account_id` | 계정 A. 다른 계정 자격증명이면 실행 거부 |
| `image_bucket_name` | 이미지 버킷 이름 |
| `domain_name` | `loom.ai.kr`. **비우면 영역 · 커스텀 도메인 · 레코드가 삭제됩니다** |
| `api_server_ip` | `api` A 레코드 대상 (EC2) |
| `extra_cors_origins` | S3 CORS 추가 출처 (기본 `http://localhost:5173`) |
| `db_account_id` · `mattermost_channel_id` | 둘 다 채우면 RDS 제어 Lambda 생성 |

<br>

## 운영 규칙

- **변경은 항상 `plan` 먼저.** 콘솔에서 직접 고친 내용은 다음 apply 때 되돌아갑니다.
- 커밋하지 않는 파일: `*.tfvars`, `backend.hcl`, `*.tfstate`. `.terraform.lock.hcl`은 provider 버전 고정용이라 커밋합니다.
- **CORS 출처는 두 곳**에서 관리합니다. 여기 `extra_cors_origins`는 S3 CORS, ansible `extra_cors_origins`는 백엔드 CORS입니다. Amplify 기본 주소와 `loom.ai.kr`은 양쪽에 자동으로 들어갑니다.
- `infra_outputs.yml`의 키 이름을 바꾸면 ansible `group_vars/all.yml`도 같이 바꿔야 합니다.

<br>

## 도메인 (`loom.ai.kr`)

| 주소 | 대상 | 인증서 |
|---|---|---|
| `loom.ai.kr` | Amplify (프론트) | Amplify 관리 |
| `www.loom.ai.kr` | Amplify → 루트로 301 | Amplify 관리 |
| `api.loom.ai.kr` | EC2 (API · Jenkins) | Let's Encrypt (ansible/) |

처음 연결하는 순서:
1. apply 후 `terraform output route53_name_servers`의 4개를 가비아 *도메인 관리 → 네임서버 설정*에 입력
2. `nslookup -type=NS loom.ai.kr 8.8.8.8`에 `awsdns`가 보이면 반영 완료
3. Amplify 콘솔의 도메인 상태가 *사용 가능*이 될 때까지 대기

<br>

## RDS 제어 (Mattermost `/rds`)

계정 B의 RDS를 허용한 Mattermost 채널에서 켜고 끕니다.

```
Mattermost /rds  →  Lambda Function URL (계정 A, 슬래시 명령 토큰 + 채널 검증)
                 →  AssumeRole loom-rds-control (계정 B)
                 →  RDS start / stop / describe
                 →  완료되면 Incoming Webhook으로 채널 알림
```

| 명령 | 동작 | 보이는 범위 |
|---|---|---|
| `/rds status` | 현재 상태 | 채널 전체 |
| `/rds start` | 시작 (5~10분) → 완료 알림 | 채널 전체 |
| `/rds stop confirm` | 중지 → 완료 알림. `confirm` 없이 `stop`만 치면 안내만 | 채널 전체 |

- 비밀값(슬래시 명령 토큰, Webhook URL)은 SSM SecureString `/loom/rds-control/*`에 직접 넣습니다.
- 중지된 RDS는 **7일 후 AWS가 자동으로 다시 켭니다.** 중지 중에는 운영 백엔드 · AI 서버도 DB 오류가 납니다. 데이터는 유지됩니다.
- 로그: CloudWatch `/aws/lambda/loom-rds-control` · 테스트: `python -m unittest discover -s modules/rds-control/tests -v`

<details>
<summary>처음 설정하는 순서</summary>

1. Mattermost: 채널 ID 확인, 같은 채널에 Incoming Webhook 생성
2. `terraform.tfvars`에 `db_account_id`, `mattermost_channel_id` 입력 → `terraform apply`
   → `terraform output rds_control_function_url`, `rds_control_lambda_role_arn` 확인
3. Mattermost *통합 → 슬래시 명령어*: 트리거 `rds`, 요청 URL = Function URL, `POST` → 발급된 토큰 복사
4. SSM 저장 (계정 A)
   ```bash
   aws ssm put-parameter --profile loom-main --region ap-northeast-2 --type SecureString \
     --name /loom/rds-control/mattermost-token --value "<토큰>"
   aws ssm put-parameter --profile loom-main --region ap-northeast-2 --type SecureString \
     --name /loom/rds-control/mattermost-webhook-url --value "<웹훅 URL>"
   ```
5. 계정 B 역할: `envs/db-account`를 `loom-db` 프로필로 apply하거나, 콘솔에서 역할 `loom-rds-control` 생성
   - 신뢰 정책: Principal `<rds_control_lambda_role_arn>`, Action `sts:AssumeRole`
   - 인라인 정책: `rds:DescribeDBInstances` · `StartDBInstance` · `StopDBInstance`, Resource `arn:aws:rds:ap-northeast-2:<계정 B>:db:loompostgres`
6. 허용 채널에서 `/rds status`

| 증상 | 원인 |
|---|---|
| Unauthorized / 응답 없음 | SSM 토큰과 슬래시 명령 토큰이 다름 |
| "이 채널에서는 사용할 수 없습니다" | `mattermost_channel_id` 불일치 |
| `AccessDenied` | 계정 B 역할이 없거나 신뢰 정책의 ARN 오타 |
| 시작은 됐는데 완료 알림 없음 | Webhook URL 오류 → CloudWatch 로그 확인 |

</details>
