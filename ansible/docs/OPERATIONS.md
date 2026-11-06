# 배포 실행 / 운영

[← README로 돌아가기](../README.md)

## 백엔드 / 서버

```bash
ansible-playbook server.yml --ask-vault-pass
```

- 최초 실행 시 Docker/Jenkins/Nginx 설치까지 포함되어 몇 분 걸립니다.
- 재실행하면 변경된 부분만 반영되고, ECR에서 이미지를 다시 pull해 컨테이너를 갱신합니다.
- 특정 태그로 배포: `ansible-playbook server.yml --ask-vault-pass -e image_tag=<커밋해시>`

확인:

```bash
ssh -i ~/.ssh/your-ec2-key.pem ubuntu@<EC2_IP>
docker compose -f /opt/loom/docker-compose.yml ps
docker compose -f /opt/loom/docker-compose.yml logs -f app
curl -s localhost:8080/actuator/health    # actuator를 추가한 경우
```

## AI 서버

외부에 포트를 열지 않으므로 서버 안에서 확인합니다.

```bash
docker compose -f /opt/loom/docker-compose.yml ps ai                                 # (healthy) 여부
docker compose -f /opt/loom/docker-compose.yml exec ai python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/health').read())"
docker compose -f /opt/loom/docker-compose.yml logs -f ai
```

- 백엔드에서는 `AI_BASE_URL`(`http://ai:8000`) 환경변수로 호출합니다.
- 퍼스널 컬러 진단 가중치는 팀 레포 `ai-models/`를 `server.yml`이 `/opt/loom/ai-models`로 복사하고 컨테이너 `/models`에 읽기 전용으로 마운트합니다.
  가중치가 바뀌면 팀 레포를 pull한 뒤 `server.yml`을 다시 실행하세요 (바뀐 파일만 전송). 경로는 `ai.env`의 `COLOR_CHECKPOINT`, `FACER_WEIGHTS_DIR`.
- 끄려면 `all.yml`에서 `enable_ai: false` 후 `server.yml` 재실행 (컨테이너도 정리됨).
- 특정 버전: `cd /opt/loom && AI_IMAGE_TAG=<커밋해시> docker compose up -d ai`

## Redis

refresh token · 소셜 가입 signupToken 저장소. 같은 compose 스택의 `loom-redis` 컨테이너이며 호스트 포트는 없습니다.

- 설정: `/opt/loom/redis.conf` (0600, 비밀번호 · AOF · `maxmemory-policy noeviction`), 데이터: `/opt/loom/redis-data`
- 비밀번호는 vault `vault_redis_password`. 바꾸면 `server.yml` 재실행 → Redis 재시작 + 백엔드 `app.env` 갱신
- 확인: `docker exec -it loom-redis redis-cli` 접속 후 `AUTH <비밀번호>` → `PING`
- Redis 데이터가 지워지면 모든 사용자가 다시 로그인해야 합니다 (`redis-data`를 지우지 마세요)

## 모니터링 (Prometheus · Grafana)

같은 compose 스택에 `loom-prometheus` · `loom-grafana` · `loom-node-exporter` · `loom-cadvisor` · `loom-redis-exporter`가 뜹니다 (S15P31A104-107).

- **화면**: `https://api.loom.ai.kr/grafana/` — `admin` / vault `vault_grafana_admin_password`. 익명 접근 · 가입은 꺼져 있습니다
- **수집 대상** (`/opt/loom/prometheus.yml`, 15초): 백엔드 `app:8081/actuator/prometheus`, AI `ai:8000/metrics`, node-exporter, cAdvisor(30초), redis-exporter
  - 백엔드 메트릭은 management 포트(8081)에만 있고 API 포트(8080, Nginx)에는 없습니다. Prometheus · exporter는 호스트 포트를 열지 않습니다
- **Prometheus 원본 화면** (쿼리 · Targets 상태): 외부에 공개하지 않으므로 SSH 터널로 엽니다
  ```bash
  ssh -L 9090:$(ssh loom-db "sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' loom-prometheus"):9090 loom-db
  # 브라우저에서 http://localhost:9090/targets
  ```
- **보관**: 15일 또는 5GB 중 먼저 닿는 쪽 (`prometheus_retention_*`), 데이터는 `/opt/loom/prometheus-data`
- **설정 변경**: `prometheus.yml` · `files/grafana/provisioning/`을 고치고 `server.yml` 재실행 → 바뀐 쪽만 재시작. 데이터소스 · 대시보드 · 알림은 Grafana 화면에서 만들지 않고 파일로 관리합니다
- **관리자 비밀번호 변경**: `GF_SECURITY_ADMIN_PASSWORD`는 첫 기동 때만 적용됩니다. 이후에는
  `docker exec -it loom-grafana grafana cli admin reset-admin-password '<새 비밀번호>'` 실행 후 vault 값도 같이 바꿔 두세요
- **끄기**: `all.yml`에서 `monitoring_enabled: false` 후 `server.yml` 재실행 (컨테이너 정리, 데이터 디렉토리는 남음)
- **자원**: 컨테이너별 `mem_limit` (Prometheus 512m · Grafana 256m · cAdvisor 192m · exporter 64m)

## 프론트엔드 (Amplify)

```bash
ansible-playbook frontend-deploy.yml
```

`npm ci` → `npm run build`(Vite 빌드 환경변수 주입) → `dist`를 zip → `create-deployment` →
업로드 → `start-deployment` → 완료(SUCCEED)까지 대기합니다. vault 비밀번호는 필요 없습니다.

- 이미 빌드했다면: `-e frontend_build=false`
- 빌드 타임 환경변수는 `all.yml`의 `frontend_build_env`에서 관리합니다 (`VITE_` 접두사만 번들에 포함).
- SPA 라우팅(새로고침 시 404)은 Terraform의 Amplify `custom_rule`로 처리돼 있습니다.
- 커스텀 도메인은 Amplify 콘솔 > 도메인 관리에서 연결한 뒤, `all.yml`의 `frontend_url`을 덮어쓰고
  `extra_cors_origins`에 추가하세요 — 이 폴더(all.yml, 백엔드 CORS)와 terraform/(tfvars, S3 CORS) 양쪽.

## Jenkins 연동

Jenkins는 같은 EC2에 설치됩니다 (`https://<API 도메인>/jenkins/`). 파이프라인은 프로젝트 레포에 있습니다.

| Jenkins 작업 | 브랜치 | Jenkinsfile | 배포 |
|---|---|---|---|
| `loom-backend` | `BE-main` | `backend/Jenkinsfile` | `backend/`, `backend_ai/` 중 바뀐 쪽만 → ECR push → 컨테이너 교체 |
| `loom-frontend` | `FE-main` | `frontend/Jenkinsfile` | `frontend/` 빌드 → Amplify |

- 백엔드 파이프라인은 컨테이너 교체를 `sudo /usr/local/bin/loom-deploy <app|ai> <태그>`로 합니다.
  `server.yml`이 이 스크립트와 sudoers(`/etc/sudoers.d/jenkins-loom-deploy`)를 설치합니다.
- 스크립트는 `/opt/loom/.env`의 `IMAGE_TAG`/`AI_IMAGE_TAG`를 바꾸고 해당 서비스만 다시 띄운 뒤,
  health 확인에 실패하면 이전 태그로 되돌립니다.
- `server.yml`을 다시 실행하면 태그가 `latest`로 돌아갑니다. Jenkins는 배포가 성공한 이미지에만 `latest`를
  붙이므로 결과는 같습니다.
- 수동 재배포/롤백: Jenkins `loom-backend` → Build with Parameters → `IMAGE_TAG`에 커밋 해시(7자리).

최초 설정 절차(플러그인, Credential, 작업, GitLab webhook)는 [JENKINS.md](JENKINS.md)를 참고하세요.

## 이미지(S3 + CloudFront)

- 객체 키 예: `images/{uuid}.webp` → 접근 URL `https://<cloudfront_domain>/images/{uuid}.webp`
- Spring에는 `AWS_S3_BUCKET`, `AWS_REGION`, `CLOUDFRONT_DOMAIN`, `AWS_ACCESS_KEY_ID/SECRET`(loom-app)이 주입됩니다.
- 같은 키로 덮어쓰면 CloudFront 캐시(기본 최대 24시간) 때문에 이전 이미지가 보일 수 있으므로
  **업로드마다 새 키(UUID)를 쓰는 방식**을 권장합니다. 불가피하면 invalidation:
  ```bash
  aws cloudfront create-invalidation --distribution-id <ID> --paths "/images/xxx.webp" --profile loom-main
  ```
- 버킷은 Terraform `prevent_destroy`로 보호되어 실수로 destroy 되지 않습니다.

## 참고

- `inventory/hosts.ini`, `group_vars/all.yml`, `group_vars/vault.yml`, `group_vars/infra_outputs.yml`, `*.pem`은
  `.gitignore`에 등록되어 커밋되지 않습니다.
- AWS 리소스 변경은 `terraform/`에서 `terraform plan` → `apply`로만 합니다.
  콘솔에서 직접 고치면 다음 apply 때 되돌려지거나 드리프트가 생깁니다.
  apply 후에는 `infra_outputs.yml`이 갱신되므로 필요하면 `server.yml`을 다시 실행하세요.
