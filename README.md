# loom-infra

**Loom** (온보딩 정보 기반 의상 추천 + AI 가상 착장 서비스) 의 인프라 코드입니다.
AWS 리소스는 **Terraform**, 서버 구성과 배포는 **Ansible**, 지속 배포는 **Jenkins**가 맡습니다.

| 폴더 | 역할 | 문서 |
|---|---|---|
| [`terraform/`](terraform) | AWS 리소스 — Route 53 · Amplify · S3/CloudFront · ECR · IAM · RDS 제어 Lambda | [terraform/README.md](terraform/README.md) |
| [`ansible/`](ansible) | EC2 구성 · 배포 — Docker · Nginx(HTTPS) · Jenkins · 백엔드/AI/Redis 컨테이너 | [ansible/README.md](ansible/README.md) |

애플리케이션 코드(Spring Boot · FastAPI · React)와 Jenkinsfile은 별도 모노레포에 있습니다.

<br>

## 아키텍처

```
  가비아(도메인 등록) ── NS ──> Route 53  loom.ai.kr
                                 ├─ loom.ai.kr · www  ──> Amplify Hosting (React 정적 파일, 인증서 Amplify 관리)
                                 └─ api.loom.ai.kr  A ──> EC2

                        ┌──────────────── AWS 계정 A (Terraform) ────────────────┐
  이미지 ───────────────┼─> CloudFront ─(OAC)─> S3 (비공개)                       │
                        │   ECR (loom-backend · loom-ai)   IAM (loom-ci · loom-app) │
                        │   Lambda (Mattermost /rds → RDS 켜기 · 끄기)             │
                        └────────────────────────────────────────────────────────┘
  https://api.loom.ai.kr
        │
  ┌─────▼──────────── EC2 (SSAFY 제공 · Ansible) ───────────────────────────┐
  │  Nginx 443 (Let's Encrypt)                                              │
  │   ├─ /          → Spring Boot ──┬─> FastAPI AI 서버 (진단 모델 마운트)     │
  │   │                             └─> Redis (AOF, 비밀번호)                 │
  │   └─ /jenkins/  → Jenkins  (BE-main · FE-main 머지 시 자동 배포)          │
  └───────────────────────│─────────────────────────────────────────────────┘
                          │ TLS 5432
                ┌─────────▼──── AWS 계정 B ────┐
                │  RDS PostgreSQL              │
                └──────────────────────────────┘
```

<br>

## 설계 컨셉

1. **도구별 책임 분리** — Terraform은 "무엇이 존재하는가"(클라우드 리소스), Ansible은 "어떻게 돌아가는가"(서버 · 컨테이너), Jenkins는 "언제 바뀌는가"(배포). 같은 대상을 두 도구가 건드리지 않습니다. (예: 프론트 DNS 레코드는 Amplify가 만들므로 Terraform에 적지 않음)
2. **사람이 값을 옮기지 않는다** — `terraform apply`가 ECR 주소 · 버킷 · CloudFront · Amplify ID · 도메인을 `ansible/group_vars/infra_outputs.yml`로 자동 기록하고, Ansible이 그대로 읽습니다.
3. **비밀은 코드 밖** — 액세스 키 · 토큰은 Terraform state에 남기지 않고(수동 발급 · SSM), 서버 비밀값은 `ansible-vault`로 암호화한 뒤 0600 env 파일로만 컨테이너에 넣습니다.
4. **최소 노출 · 최소 권한** — 외부 공개는 Nginx(80/443)뿐. AI 서버 · Redis는 내부 네트워크 전용. IAM 사용자는 용도별(CI · 앱)로 나누고, 다른 계정의 RDS에는 시작 · 중지 · 조회만 가능한 역할 하나만 둡니다.
5. **불변 이미지 + 자동 롤백** — 서버는 빌드하지 않고 커밋 해시 태그 이미지를 받기만 합니다. 배포 후 health 확인에 실패하면 이전 태그로 되돌립니다.
6. **주어진 환경 존중** — SSAFY 제공 EC2와 별도 계정의 RDS는 소유하지 않으므로 코드로 생성 · 삭제하지 않고 접속 · 구성만 합니다.

<br>

## 도메인 · 인증서

| 주소 | 연결 | 레코드 관리 | 인증서 |
|---|---|---|---|
| `loom.ai.kr`, `www` | Amplify Hosting | Amplify (같은 계정의 Route 53 영역에 자동 생성) | Amplify |
| `api.loom.ai.kr` | EC2 Nginx | Terraform (`modules/dns`) | Let's Encrypt (Ansible · certbot) |
| 이미지 | CloudFront 기본 주소 `*.cloudfront.net` | — | CloudFront 기본 |

도메인 등록은 가비아이고, 네임서버만 Route 53으로 넘겼습니다. 절차는 [terraform/README.md](terraform/README.md#도메인-loomaikr).

<br>

## 배포 흐름

```
BE-main 머지 ─> Jenkins ─ 테스트 · 이미지 빌드 ─> ECR ─> loom-deploy (EC2) ─ health 실패 시 롤백
FE-main 머지 ─> Jenkins ─ Vite 빌드 ─────────────> Amplify 수동 배포(zip)
인프라 · 설정 변경 ───────> terraform apply / ansible-playbook server.yml (사람이 실행)
```

<br>

## 설정 값은 어디서 오나

백엔드 컨테이너의 환경변수(`/opt/loom/app.env`, 0600)는 Ansible이 세 곳을 합쳐 만듭니다.

| 출처 | 예 |
|---|---|
| `infra_outputs.yml` (Terraform 자동) | S3 버킷, CloudFront 도메인, 프론트 주소 → CORS 허용 출처 · OAuth redirect 주소 |
| `all.yml` (일반 설정) | Spring 프로필, RDS 주소, AI 서버 주소, Redis 메모리 |
| `vault.yml` (암호화) | DB · JWT · 인증 코드 HMAC · Redis 비밀번호, 메일 계정, S3 키, 소셜 로그인 키 |

필수 비밀값이 비어 있으면 `server.yml`이 시작 단계에서 어느 값인지 알려주고 멈춥니다. 소셜 로그인 키는 선택이라 비어 있어도 배포되고, 그 제공자의 로그인만 실패합니다.
백엔드에 새 환경변수가 생기면 `ansible/templates/app.env.j2` · `all.yml` · `vault.yml`에 같이 추가합니다.

<br>

## 시작 순서

```
1. terraform/bootstrap      state 버킷 (최초 1회)
2. terraform/envs/prod      AWS 리소스 → ansible/group_vars/infra_outputs.yml 생성
3. 가비아 네임서버 변경      apply 출력의 Route 53 네임서버 4개
4. IAM 액세스 키 수동 발급   loom-ci → Jenkins · vault,  loom-app → vault
5. ansible/server.yml       EC2 구성 + 컨테이너 기동 (WSL에서 실행)
6. Jenkins 작업 · GitLab webhook 설정 → 이후 배포는 브랜치 머지로
```

| 문서 | 내용 |
|---|---|
| [ansible/docs/SETUP.md](ansible/docs/SETUP.md) | 처음부터 끝까지 설치 절차 |
| [ansible/docs/JENKINS.md](ansible/docs/JENKINS.md) | Jenkins 작업 · 자격증명 · webhook |
| [ansible/docs/OPERATIONS.md](ansible/docs/OPERATIONS.md) | 배포 · 롤백 · 로그 · AI 모델 · Redis 운영 |
| [terraform/README.md](terraform/README.md#rds-제어-mattermost-rds) | Mattermost `/rds` 로 RDS 켜기 · 끄기 |

<br>

## 폴더 배치

경로 기본값은 이 저장소가 애플리케이션 모노레포와 나란히 있다고 가정합니다.

```
SSAFY/
├── loom-infra/          ← 이 저장소
│   ├── terraform/
│   └── ansible/
└── S15P31A104/          ← 애플리케이션 모노레포 (frontend · backend · backend_ai · ai-models)
```

다르게 두려면 `ansible/group_vars/all.yml`의 `frontend_src_dir`, `ai_models_src_dir`를 바꾸세요.

<br>

## 커밋하지 않는 파일

실제 값이 들어가는 파일은 모두 `.gitignore`에 있고, 같은 이름의 `.example`을 복사해서 채웁니다.

| 파일 | 내용 |
|---|---|
| `terraform/**/terraform.tfvars`, `backend.hcl`, `*.tfstate` | 계정 ID · 도메인 · state |
| `ansible/group_vars/all.yml` | 서버별 설정 |
| `ansible/group_vars/vault.yml` | 비밀값 (ansible-vault 암호화해도 공개 저장소에는 올리지 않음) |
| `ansible/group_vars/infra_outputs.yml` | Terraform이 생성 |
| `ansible/inventory/hosts.ini`, `*.pem` | 서버 주소 · SSH 키 |
