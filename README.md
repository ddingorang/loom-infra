# loom-infra

**Loom**은 온보딩 정보를 바탕으로 사용자에게 적합한 의상을 추천하고, AI 가상 착장 기능을 제공하는 서비스입니다.

이 저장소는 Loom 운영에 필요한 인프라와 배포 환경을 관리합니다. AWS 리소스는 **Terraform**, 서버 구성과 컨테이너 관리는 **Ansible**, 애플리케이션의 지속적 배포는 **Jenkins**를 통해 자동화했습니다.

| 폴더 | 역할 | 관련 문서 |
|---|---|---|
| [`terraform/`](terraform) | AWS 리소스 관리 — Route 53, Amplify, S3/CloudFront, ECR, IAM, RDS 제어 Lambda | [terraform/README.md](terraform/README.md) |
| [`ansible/`](ansible) | 서버 구성 및 배포 — Docker, Nginx(HTTPS), Jenkins, 백엔드/AI/Redis 컨테이너 | [ansible/README.md](ansible/README.md) |

애플리케이션(Spring Boot, FastAPI, React)과 Jenkinsfile은 별도의 모노레포에서 관리합니다.

---

## 아키텍처

```text
가비아 (도메인 등록)
       │
       └── NS ──> Route 53 (loom.ai.kr)
                       │
                       ├── loom.ai.kr · www
                       │       └──> Amplify Hosting
                       │              (React 정적 파일 · 인증서 관리)
                       │
                       └── api.loom.ai.kr (A)
                               └──> EC2

                  ┌──────────── AWS 계정 A (Terraform) ────────────┐
                  │                                                │
                  │  CloudFront (OAC) ──> S3 (Private)              │
                  │  ECR (loom-backend · loom-ai)                  │
                  │  IAM (loom-ci · loom-app)                      │
                  │  Lambda (Mattermost /rds → RDS 제어)           │
                  │                                                │
                  └────────────────────────────────────────────────┘

https://api.loom.ai.kr
          │
          ▼
┌────────────────────── EC2 (Ansible) ─────────────────────────────┐
│                                                                  │
│  Nginx (443 · Let's Encrypt)                                     │
│   │                                                              │
│   ├── /         → Spring Boot                                    │
│   │                 ├──> FastAPI AI 서버 (진단 모델 마운트)       │
│   │                 └──> Redis (AOF · 비밀번호 인증)              │
│   │                                                              │
│   ├── /jenkins/ → Jenkins                                        │
│   │               (BE-main · FE-main 병합 시 자동 배포)           │
│   │                                                              │
│   └── /grafana/ → Grafana ◀── Prometheus ◀── 백엔드 · AI · exporter │
│                   (대시보드 · 알림, 로그인 필수)                   │
│                                                                  │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           │ TLS (5432)
                           ▼
                ┌──────── AWS 계정 B ────────┐
                │                            │
                │       RDS PostgreSQL       │
                │                            │
                └────────────────────────────┘
```

## 설계 원칙

### 1. 도구별 책임 분리

인프라의 생성부터 애플리케이션 배포까지 각 도구의 역할을 명확하게 구분했습니다.

- **Terraform**: AWS 리소스의 생성과 관리
- **Ansible**: 서버 환경 구성 및 Docker 컨테이너 관리
- **Jenkins**: 코드 변경 감지, 이미지 빌드 및 애플리케이션 배포

동일한 리소스를 여러 도구가 중복 관리하지 않도록 구성했습니다. 예를 들어 프론트엔드 도메인 레코드는 Amplify가 자동으로 생성하므로 Terraform에서 별도로 관리하지 않습니다.

### 2. 인프라 정보 자동 연동

도구 간 설정값을 수동으로 전달하는 과정을 줄이고, 인프라 구성 정보를 자동으로 연동하도록 했습니다.

`terraform apply` 실행 후 ECR 주소, S3 버킷, CloudFront 도메인, Amplify ID, 도메인 등 주요 출력값을 `ansible/group_vars/infra_outputs.yml`에 자동으로 기록합니다.

Ansible은 해당 파일을 참조하여 서버 구성과 애플리케이션 배포에 필요한 정보를 사용합니다. 이를 통해 반복적인 수작업을 줄이고 도구 간 설정값의 일관성을 유지합니다.

### 3. 비밀 정보 분리 및 보호

인증 정보와 민감한 환경변수가 코드나 설정 파일에 직접 노출되지 않도록 분리했습니다.

- AWS 액세스 키와 토큰은 Terraform State에 저장하지 않고 별도로 발급하여 관리합니다.
- 필요한 인증 정보는 SSM 등 별도 경로를 통해 관리합니다.
- 서버 환경변수는 `ansible-vault`로 암호화하여 관리합니다.
- 복호화된 환경변수는 권한을 `0600`으로 제한한 파일에 기록하고 컨테이너에 전달합니다.
- 실제 비밀값이 포함된 파일은 `.gitignore`에 등록하여 저장소에 포함되지 않도록 합니다.

### 4. 최소 노출 및 최소 권한

외부 접근 지점을 최소화하고, 서비스 내부 구성 요소는 필요한 범위에서만 통신하도록 설계했습니다.

- 외부에 공개하는 포트는 Nginx의 HTTP(80), HTTPS(443)로 제한합니다.
- FastAPI AI 서버와 Redis는 내부 네트워크에서만 접근할 수 있도록 구성합니다.
- IAM 사용자는 용도에 따라 CI/CD용(`loom-ci`)과 애플리케이션용(`loom-app`)으로 분리합니다.
- 별도 AWS 계정의 RDS는 시작, 중지, 조회에 필요한 최소 권한만 부여한 역할을 통해 제어합니다.

### 5. 불변 이미지 기반 배포 및 자동 롤백

서버에서 애플리케이션을 직접 빌드하지 않고, ECR에 등록된 Docker 이미지를 내려받아 실행하는 방식을 적용했습니다.

- 커밋 해시를 이미지 태그로 사용하여 배포 버전을 식별합니다.
- 서버는 빌드 과정 없이 지정된 버전의 이미지를 가져와 실행합니다.
- 배포 후 Health Check를 통해 서비스 정상 여부를 확인합니다.
- Health Check에 실패하면 이전 이미지 태그를 사용하여 자동으로 롤백합니다.

이를 통해 배포 환경의 일관성을 유지하고, 신규 버전 적용 중 발생할 수 있는 장애에 대응할 수 있도록 했습니다.

### 6. 기존 인프라 환경 고려

기존에 제공된 EC2와 별도 AWS 계정에 위치한 RDS를 활용합니다.

직접 소유하거나 생성 및 삭제하지 않는 리소스는 기존 환경을 유지하면서 필요한 서버 구성과 연결만 관리하도록 했습니다.

---

## 도메인 및 인증서 관리

도메인은 가비아에서 등록하고, 네임서버를 Route 53으로 변경하여 DNS를 관리합니다.

각 서비스의 연결과 인증서는 서비스 특성에 맞게 관리 주체를 분리했습니다.

| 주소 | 연결 대상 | DNS 레코드 관리 | 인증서 관리 |
|---|---|---|---|
| `loom.ai.kr` | Amplify Hosting | Amplify (Route 53 영역에 자동 생성) | Amplify |
| `www.loom.ai.kr` | Amplify Hosting | Amplify (Route 53 영역에 자동 생성) | Amplify |
| `api.loom.ai.kr` | EC2 Nginx | Terraform (`modules/dns`) | Let's Encrypt (Ansible · Certbot) |
| 이미지 | CloudFront 기본 도메인 (`*.cloudfront.net`) | 별도 도메인 레코드 없음 | CloudFront 기본 인증서 |

도메인 등록은 가비아에서 진행하며, 네임서버만 Route 53으로 위임합니다.

자세한 설정 절차는 [Terraform 도메인 설정 가이드](terraform/README.md#도메인-loomaikr)를 참고하세요.

---

## 배포 흐름

프론트엔드와 백엔드의 배포 방식을 분리하여 각 서비스에 적합한 방식으로 배포합니다.

### 백엔드

```text
BE-main 병합
    │
    ▼
  Jenkins
    │
    ├── 테스트 실행
    │
    ├── Docker 이미지 빌드
    │
    ▼
    ECR
    │
    ▼
loom-deploy (EC2)
    │
    ├── 신규 이미지 배포
    │
    ├── Health Check
    │
    └── 실패 시 이전 버전으로 롤백
```

### 프론트엔드

```text
FE-main 병합
    │
    ▼
  Jenkins
    │
    ├── Vite 빌드
    │
    └── 배포 파일 ZIP 생성
             │
             ▼
       Amplify 수동 배포
```

### 인프라 및 서버 설정 변경

Terraform과 Ansible을 통한 인프라 및 서버 설정 변경은 필요에 따라 직접 명령어를 실행합니다.

```bash
terraform apply

ansible-playbook server.yml
```

---

## 환경변수 및 설정 관리

백엔드 컨테이너에 전달되는 환경변수 파일은 `/opt/loom/app.env`에 생성되며, 파일 권한은 `0600`으로 제한합니다.

Ansible은 다음 세 가지 설정 파일을 조합하여 환경변수를 구성합니다.

| 설정 파일 | 관리 방식 | 주요 항목 |
|---|---|---|
| `infra_outputs.yml` | Terraform 자동 생성 | S3 버킷, CloudFront 도메인, 프론트엔드 주소, CORS 허용 출처, OAuth Redirect URI |
| `all.yml` | 일반 설정 | Spring 프로필, RDS 주소, AI 서버 주소, Redis 메모리 설정 |
| `vault.yml` | Ansible Vault 암호화 | DB, JWT, 인증 코드 HMAC, Redis 비밀번호, 메일 계정, S3 키, 소셜 로그인 키 |

**환경변수 검증**

- 필수 비밀값이 누락된 경우 `server.yml` 실행 초기에 누락된 항목을 안내하고 작업을 중단합니다.
- 소셜 로그인 키는 선택 항목으로 관리합니다. 값이 없는 경우에도 배포는 진행되며, 해당 제공자의 로그인 기능만 사용할 수 없습니다.
- 백엔드에 새로운 환경변수가 추가되면 `ansible/templates/app.env.j2`, `all.yml`, `vault.yml`에도 관련 항목을 함께 반영해야 합니다.

---

## 시작하기

초기 인프라 구축은 다음 순서로 진행합니다.

| 순서 | 작업 | 설명 |
|---|---|---|
| 1 | Terraform Bootstrap | Terraform State 저장용 S3 버킷 생성 (최초 1회) |
| 2 | Terraform Apply | AWS 리소스 생성 및 `infra_outputs.yml` 생성 |
| 3 | 네임서버 변경 | Apply 결과로 출력된 Route 53 네임서버 4개를 가비아에 등록 |
| 4 | IAM 인증 정보 발급 | `loom-ci`는 Jenkins 및 Vault에, `loom-app`은 Vault에 등록 |
| 5 | Ansible 실행 | EC2 초기 설정 및 컨테이너 기동 |
| 6 | Jenkins 연동 | Jenkins 작업 및 GitLab Webhook 설정 |

초기 설정이 완료되면 이후 애플리케이션 배포는 GitLab 브랜치 병합을 통해 진행됩니다.

### 상세 문서

| 문서 | 설명 |
|---|---|
| [Ansible 초기 구축 가이드](ansible/docs/SETUP.md) | 인프라 초기 설정부터 서버 구성까지 전체 설치 절차 |
| [Jenkins 설정 가이드](ansible/docs/JENKINS.md) | Jenkins 작업, 인증 정보 및 Webhook 설정 |
| [운영 가이드](ansible/docs/OPERATIONS.md) | 배포, 롤백, 로그, AI 모델 및 Redis 관리 |
| [Terraform RDS 제어 가이드](terraform/README.md#rds-제어-mattermost-rds) | Mattermost `/rds` 명령어를 통한 RDS 시작 및 중지 |

---

## 디렉터리 구조

이 저장소는 애플리케이션 모노레포와 동일한 상위 디렉터리에 위치하는 것을 기본으로 합니다.

```text
SSAFY/
├── loom-infra/                  # 인프라 관리 저장소
│   ├── terraform/               # AWS 리소스 관리
│   └── ansible/                 # 서버 구성 및 배포
│
└── S15P31A104/                  # 애플리케이션 모노레포
    ├── frontend/
    ├── backend/
    ├── backend_ai/
    └── ai-models/
```

저장소 위치가 다른 경우 `ansible/group_vars/all.yml`에서 다음 경로를 수정하면 됩니다.

- `frontend_src_dir`
- `ai_models_src_dir`

---

## Git 관리 제외 파일

계정 정보, 인증 정보, 실제 환경 설정 등 민감한 값이 포함되는 파일은 Git 관리 대상에서 제외합니다.

각 설정 파일은 저장소에 제공된 동일한 이름의 `.example` 파일을 복사한 뒤 실제 환경에 맞게 작성합니다.

| 파일 및 경로 | 용도 |
|---|---|
| `terraform/**/terraform.tfvars` | AWS 계정 ID, 도메인 등 환경별 설정 |
| `terraform/**/backend.hcl` | Terraform State Backend 설정 |
| `terraform/**/*.tfstate` | Terraform State 및 리소스 상태 정보 |
| `ansible/group_vars/all.yml` | 서버 및 애플리케이션 설정 |
| `ansible/group_vars/vault.yml` | Ansible Vault로 관리하는 비밀 정보 |
| `ansible/group_vars/infra_outputs.yml` | Terraform에서 생성하는 인프라 연동 정보 |
| `ansible/inventory/hosts.ini` | 서버 접속 정보 |
| `*.pem` | SSH 개인 키 |

> `ansible/group_vars/vault.yml`은 Ansible Vault로 암호화한 경우에도 공개 저장소에는 커밋하지 않는 것을 원칙으로 합니다.