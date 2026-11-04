# Jenkins 배포 파이프라인 설정

모노레포(`S15P31A104`)를 두 개의 배포 브랜치로 나눠 배포합니다.

| Jenkins 작업 | 트리거 브랜치 | Jenkinsfile | 하는 일 |
|---|---|---|---|
| `loom-backend` | `BE-main` | `backend/Jenkinsfile` | `backend/`, `backend_ai/` 중 바뀐 쪽만 test → build → ECR push → 컨테이너 교체 |
| `loom-frontend` | `FE-main` | `frontend/Jenkinsfile` | `frontend/`가 바뀌면 lint → build → Amplify 배포 |

머지하면 GitLab이 해당 브랜치의 push 이벤트를 Jenkins에 보내고, 그 브랜치를 맡은 작업만 실행됩니다.

## 변경 감지

**백엔드 / AI** — 서버에 실제로 떠 있는 버전과 비교합니다.

- Jenkins가 빌드하는 이미지에는 커밋 라벨(`org.opencontainers.image.revision`)이 붙습니다.
- 빌드 시작 시 `loom-backend`, `loom-ai` 컨테이너의 라벨을 읽고, 그 커밋 이후 `backend/` 또는
  `backend_ai/`가 바뀐 서비스만 배포합니다 (`git diff <배포된 커밋> <지금 커밋> -- backend/`).
- 서비스별로 따로 비교하므로, 한쪽만 실패하거나 수동으로 한쪽만 배포해도 다른 쪽 변경이 누락되지 않습니다.
- 컨테이너가 없거나 라벨이 없으면(Jenkins 도입 전 수동 빌드 이미지) 배포합니다.
  그래서 Jenkins 첫 빌드는 백엔드와 AI를 모두 한 번 배포합니다.
- `IMAGE_TAG`로 예전 버전으로 롤백한 뒤 다음 머지가 오면, 그 서비스는 다시 브랜치 최신 버전으로 배포됩니다.
  롤백을 유지하려면 원인 커밋을 revert해서 머지하세요.

**프론트** — Amplify에는 커밋 정보가 남지 않아 **이 작업의 마지막 성공 빌드 커밋**과 비교합니다
(`git diff --name-only $GIT_PREVIOUS_SUCCESSFUL_COMMIT $GIT_COMMIT`).
실패한 빌드의 변경분은 다음 빌드 범위에 남고, 첫 빌드는 무조건 배포합니다.

## 백엔드 배포 흐름

```
변경 감지 → ECR 로그인
  backend 변경: gradle test → docker build(:커밋7자리) → push → loom-deploy app → :latest 이동
  backend_ai 변경: pytest(컨테이너) → docker build → push → loom-deploy ai → :latest 이동
→ Mattermost 알림 → 파이프라인이 만든 이미지 중 7일 지난 미사용 이미지/빌드 캐시 정리
```

- Jenkins와 앱이 같은 Docker 데몬을 쓰므로 방금 빌드한 이미지를 서버가 다시 pull하지 않습니다.
- 컨테이너 교체는 `sudo /usr/local/bin/loom-deploy <app|ai> <태그>` (server.yml이 설치).
  `app.env`/`ai.env`는 0600이라 jenkins 사용자가 직접 compose를 실행하지 못하고, sudoers에는 이 스크립트 하나만 허용됩니다.
- 스크립트는 `/opt/loom/.env`의 태그를 바꾸고 해당 서비스만 다시 띄운 뒤 health를 확인합니다.
  - app: `127.0.0.1:8080`이 HTTP 응답(5xx 제외, 401도 정상)을 줄 때까지
  - ai: compose healthcheck(`/health`)가 `healthy`가 될 때까지
  - 180초 안에 안 되면 **이전 태그로 되돌리고** 빌드를 실패 처리합니다.
- `latest`는 배포에 성공한 이미지에만 붙습니다. 그래서 `server.yml`을 다시 실행해도(태그가 `latest`로 돌아감) 같은 이미지가 뜹니다.

## 최초 설정

### 1. 서버에 배포 스크립트 설치

```bash
cd /mnt/c/SSAFY/loom-infra/ansible
ansible-playbook server.yml --ask-vault-pass
```

`/usr/local/bin/loom-deploy`와 `/etc/sudoers.d/jenkins-loom-deploy`가 생깁니다.

### 2. Jenkins 기본 설정

`http://<EC2 IP>/jenkins/` 접속 → 추천 플러그인 설치 → 관리자 계정 생성.

- **Manage Jenkins → Plugins**: `GitLab` 플러그인 추가 설치 (Pipeline, Git, Credentials Binding, JUnit은 추천 플러그인에 포함)
- **Manage Jenkins → System → Jenkins URL**: `http://<EC2 IP>/jenkins/` (알림의 빌드 링크에 사용)

### 3. Credential 등록

Manage Jenkins → Credentials → (global) → Add Credentials

| ID | 종류 | 값 |
|---|---|---|
| `gitlab-ssafy` | Username with password | GitLab 아이디 / Personal(또는 Project) Access Token (`read_repository`) |
| `aws-loom-ci` | Username with password | Username = `loom-ci` Access Key ID, Password = Secret Access Key |
| `mattermost-webhook` | Secret text | Mattermost Incoming Webhook URL (선택, 없으면 알림만 생략) |

`loom-ci`는 ECR push/pull과 Amplify 배포 권한만 있습니다 (terraform `modules/iam`).

### 4. 작업 만들기 (2개)

New Item → 이름 `loom-backend` → **Pipeline**

- **Build Triggers**: `Build when a change is pushed to GitLab` 체크
  - `Push Events`만 체크 (나머지 해제)
  - 고급 → `Filter branches by name` → Include: `BE-main`
  - 고급 → `Secret token` → Generate (GitLab webhook에 입력)
- **Pipeline**
  - Definition: `Pipeline script from SCM` / SCM: Git
  - Repository URL: `https://lab.ssafy.com/s15-final/S15P31A104.git`, Credentials: `gitlab-ssafy`
  - Branch Specifier: `*/BE-main`
  - Script Path: `backend/Jenkinsfile`

`loom-frontend`도 같은 방식으로 만들고 브랜치만 `FE-main`, Script Path만 `frontend/Jenkinsfile`로 바꿉니다.

> 저장소 고급 설정에서 **shallow clone을 켜지 마세요.** 변경 감지에 이전 커밋이 필요합니다.
> 사용하는 플러그인 기본 기능: Pipeline, Git, Credentials Binding, JUnit (추천 플러그인에 모두 포함).

### 5. GitLab webhook

GitLab 레포 → Settings → Webhooks → Add new webhook (작업마다 하나씩)

| 항목 | loom-backend | loom-frontend |
|---|---|---|
| URL | `http://<EC2 IP>/jenkins/project/loom-backend` | `http://<EC2 IP>/jenkins/project/loom-frontend` |
| Secret token | 4단계에서 생성한 값 | 〃 |
| Trigger | Push events, 브랜치 필터 `BE-main` | Push events, 브랜치 필터 `FE-main` |
| SSL verification | HTTP면 해제 | 〃 |

저장 후 Test → Push events로 Jenkins에 빌드가 생기는지 확인합니다.

### 6. 브랜치

- `BE-main`, `FE-main`을 만들고 Jenkinsfile이 포함된 상태여야 합니다.
- GitLab → Settings → Repository → Protected branches에서 두 브랜치를 MR로만 머지되게 보호하세요.
- 첫 빌드는 전체 배포가 한 번 돕니다(위 변경 감지 참고). 이 빌드가 끝나야 Build with Parameters 화면에 파라미터가 나타납니다.

## 수동 배포 / 롤백

Jenkins → `loom-backend` → Build with Parameters

| 하고 싶은 일 | DEPLOY_TARGET | IMAGE_TAG |
|---|---|---|
| 지금 커밋 강제 재배포 | `backend` / `ai` / `all` | (비움) |
| 예전 버전으로 롤백 | `backend` / `ai` / `all` | 커밋 해시 7자리 (ECR에 있는 태그) |

롤백은 빌드 없이 ECR에서 그 태그를 pull해서 교체합니다.
프론트는 `loom-frontend` → `FORCE_DEPLOY` 체크로 강제 배포합니다. 프론트 롤백은 Amplify 콘솔의 이전 배포에서 "재배포"를 쓰세요.

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| `sudo: a password is required` | 1단계(server.yml 재실행)를 안 함 |
| `permission denied ... docker.sock` | jenkins가 docker 그룹 추가 후 재시작되지 않음 → `sudo systemctl restart jenkins` |
| `BE-main 브랜치만 배포합니다` | 작업의 Branch Specifier가 다른 브랜치를 가리킴 |
| `docker-compose.yml에 'ai' 서비스가 없습니다` | ECR에 AI 이미지가 없을 때 server.yml을 실행해 ai가 빠진 상태 → 이미지 push 후 server.yml 재실행 |
| 백엔드 테스트에서 5432 포트 충돌 | 이전 테스트 DB가 남음 → `docker compose -f backend/compose.yaml down -v` (작업 공간에서) |
| Amplify `BadRequestException` (pending job) | 이전 배포 job이 아직 진행 중 → 콘솔에서 끝나거나 취소된 뒤 재실행 |
| webhook이 와도 빌드 안 됨 | Jenkins 작업의 브랜치 필터 / GitLab webhook 브랜치 필터 / Secret token 확인 |
