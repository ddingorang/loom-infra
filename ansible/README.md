# ansible/

Loom 서비스의 **API 서버(EC2) 구성과 배포**를 코드로 관리합니다.
AWS 리소스 생성은 [terraform/](../terraform)이 맡고, 이 폴더는 그 결과를 받아 서버를 "실제로 돌아가게" 만듭니다.

<br>

## 설계 컨셉

| 원칙 | 내용 |
|---|---|
| **서버 하나, 컨테이너 여럿** | EC2 한 대에 Nginx · Jenkins는 호스트에, 백엔드 · AI · Redis는 하나의 docker compose 스택으로 둡니다. 학습 프로젝트 규모에 맞춰 단순하게 |
| **외부에는 Nginx만** | 공개 포트는 22 · 80 · 443뿐입니다. Spring은 루프백, AI 서버 · Redis는 compose 내부 네트워크에서만 접근합니다 |
| **이미지는 빌드하지 않고 받기만** | 서버는 ECR에서 이미지를 pull해 실행만 합니다. 빌드는 Jenkins가 커밋 해시 태그로 합니다. 그래서 어떤 버전이든 태그 하나로 다시 띄울 수 있습니다 |
| **비밀은 vault와 0600 파일로** | 비밀값은 `ansible-vault`로 암호화하고, 서버에서는 권한 0600 env 파일로만 컨테이너에 넣습니다. compose 파일 · 명령줄 · 로그에 남기지 않습니다(`no_log`) |
| **실패하면 되돌리기** | Jenkins 배포는 `loom-deploy` 스크립트로 컨테이너를 바꾸고, health 확인에 실패하면 이전 태그로 자동 롤백합니다 |
| **멱등 · 안전한 재실행** | `server.yml`은 몇 번을 돌려도 같은 결과입니다. 값이 빠졌으면 시작 전에 멈추고, DNS가 준비 안 됐으면 HTTPS를 건너뛰고 HTTP로 계속 서비스합니다 |
| **주어진 것에 접속만** | RDS(계정 B)는 만들지 않고 접속만 합니다. 배포 전에 EC2 → RDS 도달 여부를 검사합니다 |

<br>

## 전체 구성

```
 브라우저 ── https://loom.ai.kr ──> Amplify (프론트, terraform/)
    │
    └──── https://api.loom.ai.kr ──┐
                                   ▼
 ┌──────────────── EC2 x.xx.xx.xx (SSAFY 제공) ─────────────────────────────────┐
 │  Nginx :80 → 443 리다이렉트, :443 TLS (Let's Encrypt, 자동 갱신)              │
 │   ├─ /          ─> Spring Boot   127.0.0.1:8080   [loom-backend]             │
 │   │                  ├─> AI FastAPI  http://ai:8000   [loom-ai]  ── /models (가중치, 읽기 전용)
 │   │                  └─> Redis       redis:6379       [loom-redis] ── /opt/loom/redis-data (AOF)
 │   ├─ /jenkins/  ─> Jenkins       127.0.0.1:9090                              │
 │   └─ /grafana/  ─> Grafana       127.0.0.1:3000   [loom-grafana]             │
 │                      └─< Prometheus [loom-prometheus] ← app:8081 · ai:8000 · exporter
 │  UFW: 22 · 80 · 443만 허용                                                   │
 └───────────────────────│──────────────────────────────────────────────────────┘
                         │ 5432 (TLS, 인터넷 경유)
               ┌─────────▼──── AWS 계정 B ─────────┐     이미지: CloudFront → S3 (terraform/)
               │  RDS PostgreSQL loompostgres      │     컨테이너 이미지: ECR (terraform/)
               └───────────────────────────────────┘
```

| 구성 요소 | 방식 | 이유 |
|---|---|---|
| 백엔드 (Spring Boot) | ECR 이미지 → compose `app` | Nginx 뒤 루프백 바인딩 |
| AI 서버 (FastAPI) | ECR 이미지 → compose `ai`, 외부 비공개 | 백엔드만 내부에서 호출. 진단 모델 가중치(약 950MB)는 이미지에 굽지 않고 `/opt/loom/ai-models`를 읽기 전용 마운트 |
| Redis | compose `redis`, 외부 비공개, 비밀번호 + AOF | refresh token · 소셜 가입 저장소. ElastiCache는 같은 VPC에서만 접속 가능한데 EC2가 계정 A VPC 밖이라 컨테이너로 운영 |
| DB | 계정 B의 RDS에 TLS로 접속 | 이미 구성된 자원. 개발과 운영이 같은 DB |
| 프론트 | Amplify 수동 배포 (zip) | `lab.ssafy.com`은 Amplify Git 연동 미지원 |
| CI/CD | 같은 EC2의 Jenkins | `BE-main` · `FE-main` 머지 시 자동 배포 |
| 모니터링 | compose `prometheus` · `grafana` · `node-exporter` · `cadvisor` · `redis-exporter` | Grafana만 `/grafana/`로 공개(로그인 필수). 수집 대상 · exporter는 내부 전용. 컨테이너마다 메모리 상한 |

<br>

## 배포 흐름

```
 BE-main 머지 ─> GitLab webhook ─> Jenkins loom-backend
                                   ├─ backend/ 또는 backend_ai/ 중 바뀐 쪽만 (실행 중 컨테이너의 revision 라벨과 비교)
                                   ├─ test → docker build(커밋 해시 태그) → ECR push
                                   └─ sudo loom-deploy <app|ai> <태그>
                                        ├─ .env 태그 교체 → 해당 서비스만 재기동
                                        ├─ health 확인 (최대 180초)
                                        └─ 실패 시 이전 태그로 롤백 · 성공 시 latest 태그 이동

 FE-main 머지 ─> Jenkins loom-frontend ─> npm ci · lint · build ─> zip ─> Amplify create/start-deployment

 서버 설정 · 환경변수 변경 ─> (WSL) ansible-playbook server.yml
```

Jenkins는 sudoers로 `loom-deploy` 하나만 root로 실행할 수 있습니다. env 파일이 0600이라 jenkins 사용자가 compose를 직접 다루지 않게 하기 위함입니다.

<br>

## Playbook

| Playbook | 대상 | 하는 일 | 언제 |
|---|---|---|---|
| `server.yml` | EC2 | Docker · Jenkins · Nginx(+HTTPS) · UFW · RDS 연결 확인 · ECR 로그인 · AI 가중치 복사 · env 파일 · 컨테이너 기동 | 최초 1회, 서버 설정이나 환경변수를 바꿀 때 |
| `frontend-deploy.yml` | localhost | 프론트 빌드 → zip → Amplify 배포 → 완료 대기 | 수동 배포가 필요할 때 (평소엔 Jenkins) |
| `site.yml` | — | 위 두 개를 순서대로 | 최초 1회 (선택) |

`server.yml`의 주요 단계: 사전 검증(필수 값 · Terraform 출력) → 패키지 · Docker → Jenkins → Nginx · 인증서 → UFW → RDS 도달 확인 → ECR 로그인 · AI 이미지 확인 → AI 가중치 복사 → compose · env · redis.conf 배치 → `loom-deploy` 설치 → 컨테이너 기동.

<br>

## 디렉토리

```
ansible/
├── ansible.cfg                  # WSL /mnt/c 에선 무시됨 → 실행 시 -i 필수
├── requirements.yml             # community.docker
├── server.yml · frontend-deploy.yml · site.yml
├── inventory/hosts.ini          # 대상 서버 (커밋 안 함, .example 있음)
├── group_vars/
│   ├── all.yml                  # 일반 설정 (커밋 안 함, .example 있음)
│   ├── vault.yml                # 비밀값, ansible-vault 암호화
│   └── infra_outputs.yml        # `terraform/`이 자동 생성 (직접 수정 금지)
├── templates/
│   ├── docker-compose.yml.j2    # app · ai · redis + 모니터링 스택
│   ├── prometheus.yml.j2        # 수집 대상 (compose 서비스 이름)
│   ├── grafana.env.j2 · redis-exporter.env.j2   # 모니터링 비밀값 (0600)
│   ├── env.j2                   # compose 변수 (ECR 주소, 이미지 태그)
│   ├── app.env.j2 · ai.env.j2   # 컨테이너 환경변수 (0600)
│   ├── redis.conf.j2            # Redis 비밀번호 · AOF · noeviction (0600)
│   ├── loom-deploy.sh.j2        # Jenkins용 교체 · 롤백 스크립트
│   └── nginx-loom.conf.j2
├── files/grafana/provisioning/  # Grafana 데이터소스 · 대시보드 · 알림 (코드로만 관리)
└── docs/
    ├── SETUP.md                 # 처음 구성하는 순서 (Terraform → Ansible)
    ├── RDS.md                   # 계정 B RDS 접속 · SSL · 연결 검사
    ├── OPERATIONS.md            # 배포 · 확인 · AI 서버 · Redis · 모니터링 · 이미지 운영
    └── JENKINS.md               # 플러그인 · Credential · 작업 · GitLab webhook · 롤백
```

<br>

## 시작하기

전제: terraform `envs/prod`에서 `terraform apply`를 마쳐 `group_vars/infra_outputs.yml`이 있어야 합니다.

```bash
# WSL에서 실행
cd /mnt/c/SSAFY/loom-infra/ansible
ansible-galaxy collection install -r requirements.yml       # 최초 1회
cp inventory/hosts.ini.example inventory/hosts.ini           # 최초 1회
cp group_vars/all.yml.example group_vars/all.yml
cp group_vars/vault.yml.example group_vars/vault.yml && ansible-vault encrypt group_vars/vault.yml

ansible-playbook -i inventory/hosts.ini server.yml --ask-vault-pass
```

> **`-i inventory/hosts.ini`를 꼭 붙이세요.** WSL의 `/mnt/c`는 누구나 쓸 수 있는 폴더로 취급돼 Ansible이 `ansible.cfg`를 무시합니다. 빠뜨리면 "no hosts matched"로 아무것도 하지 않고 끝납니다.

자세한 순서는 [docs/SETUP.md](docs/SETUP.md)에 있습니다.

<br>

## 설정 값

**일반 설정 (`group_vars/all.yml`)** — 도메인 `api.loom.ai.kr`, RDS 접속 주소, 포트, AI 가중치 경로(`ai_models_*`), Redis 이미지 · 메모리, CORS 추가 출처 등.
AWS 리소스 이름 · ID는 여기 적지 않고 `infra_outputs.*`에서 읽습니다.

**비밀값 (`group_vars/vault.yml`)** — 시작할 때 비었으면 어느 값인지 알려주고 멈춥니다.

| 키 | 내용 |
|---|---|
| `vault_db_password` | RDS 비밀번호 |
| `vault_jwt_secret` | JWT 서명 키 (`openssl rand -base64 64`) |
| `vault_verification_secret` | 인증 코드 HMAC 키, 32자 이상 (`openssl rand -base64 48`) |
| `vault_redis_password` | 운영 Redis 비밀번호 (`openssl rand -hex 24`) |
| `vault_grafana_alert_webhook_url` | Grafana 알림을 보낼 Mattermost 수신 웹훅 (선택, 비우면 알림 없이 대시보드만) |
| `vault_grafana_admin_password` | Grafana `admin` 비밀번호 (`openssl rand -base64 18`). `monitoring_enabled: true`일 때 필수 |
| `vault_mail_username` · `vault_mail_password` | 인증 메일 Gmail 주소 · 앱 비밀번호 (공백 없이) |
| `vault_{kakao,google,naver}_client_id` · `_client_secret` | 소셜 로그인 키. **선택** — 비어 있어도 배포는 되고 그 제공자 로그인만 실패 |
| `vault_ecr_access_key_id` · `vault_ecr_secret_access_key` | `loom-ci` 키 (ECR pull) |
| `vault_s3_access_key_id` · `vault_s3_secret_access_key` | `loom-app` 키 (S3 업로드) |

백엔드에 새 필수 환경변수가 생기면 `templates/app.env.j2` · `all.yml` · `vault.yml`에 추가하고 `server.yml`을 다시 실행해야 합니다.
빠뜨린 채 배포하면 Spring 기동이 실패하고 `loom-deploy`가 이전 버전으로 롤백합니다.

<br>

## 운영 메모

- **`server.yml` 재실행은 안전합니다.** 바뀐 부분만 반영하고, 이미지 태그는 `latest`(= Jenkins가 마지막으로 성공 배포한 버전)로 맞춥니다. env · 설정 파일이 바뀌면 해당 컨테이너가 다시 뜹니다.
- **HTTPS**: DNS가 이 서버를 가리킬 때만 인증서를 발급하고, 인증서가 있을 때만 80 → 443 리다이렉트를 켭니다. 인증서 없이 리다이렉트해서 서비스가 끊기는 일을 막기 위함입니다.
- **Redis 데이터(`/opt/loom/redis-data`)를 지우지 마세요.** 모든 사용자가 다시 로그인해야 합니다.
- **AI 가중치**가 바뀌면 팀 레포를 pull한 뒤 `server.yml`을 다시 실행하면 바뀐 파일만 올라갑니다.
- 확인 명령, 롤백, 이미지 캐시 무효화 같은 운영 절차는 [docs/OPERATIONS.md](docs/OPERATIONS.md)를 참고하세요.

| 증상 | 원인 · 조치 |
|---|---|
| "no hosts matched" | `-i inventory/hosts.ini` 누락 |
| "○○ 값을 채워주세요 (현재 0자)" | vault에 해당 키가 비어 있음 → `ansible-vault edit` |
| RDS 연결 확인에서 중단 | RDS가 꺼져 있음(Mattermost `/rds status`) 또는 계정 B 보안그룹에 EC2 IP 없음 |
| HTTPS가 안 켜짐 | DNS가 아직 이 서버를 가리키지 않음 → 확인 후 재실행 |
| 배포 후 기동 실패 · 롤백 | 새 필수 환경변수 누락 또는 Flyway 마이그레이션 버전 중복 |
