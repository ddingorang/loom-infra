"""Mattermost 슬래시 커맨드(/rds)로 다른 계정(B)의 RDS 인스턴스를 시작/중지/조회한다.

호출 경로
1) Mattermost → Lambda Function URL (form-urlencoded 슬래시 커맨드 요청)
   - 커맨드 토큰과 허용 채널을 검증하고 즉시 응답한다 (Mattermost 응답 대기 시간 내).
   - start/stop 요청이면 자기 자신을 비동기 호출해 완료를 기다리게 한다.
2) 비동기 자기 호출 ({"action": "wait", ...})
   - RDS 상태가 목표 상태가 될 때까지 폴링한 뒤 Incoming Webhook으로 결과를 채널에 알린다.
"""

import base64
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

DB_INSTANCE_ID = os.environ.get("DB_INSTANCE_ID", "")
DB_REGION = os.environ.get("DB_REGION", "ap-northeast-2")
TARGET_ROLE_ARN = os.environ.get("TARGET_ROLE_ARN", "")
ALLOWED_CHANNEL_ID = os.environ.get("ALLOWED_CHANNEL_ID", "")
TOKEN_PARAM = os.environ.get("TOKEN_PARAM", "")
WEBHOOK_PARAM = os.environ.get("WEBHOOK_PARAM", "")

POLL_INTERVAL_SECONDS = 20
# Lambda 타임아웃 직전에 "아직 진행 중" 알림을 보낼 여유
DEADLINE_MARGIN_MS = 30_000

STATUS_LABELS = {
    "available": "🟢 실행 중 (available)",
    "stopped": "⚫ 중지됨 (stopped)",
    "starting": "🟡 시작 중 (starting)",
    "stopping": "🟡 중지 중 (stopping)",
    "backing-up": "🟡 백업 중 (backing-up)",
    "modifying": "🟡 변경 중 (modifying)",
    "rebooting": "🟡 재부팅 중 (rebooting)",
}

HELP_TEXT = (
    "**/rds 사용법**\n"
    "- `/rds status` : 현재 상태 조회\n"
    "- `/rds start` : 시작 (완료되면 채널에 알림, 보통 5~10분)\n"
    "- `/rds stop confirm` : 중지 (실수 방지를 위해 `confirm` 필요)\n"
    "\n"
    "⚠️ 중지된 RDS는 7일이 지나면 AWS가 자동으로 다시 시작합니다."
)

_param_cache = {}


# ---------------------------------------------------------------- AWS 클라이언트
def _boto3():
    import boto3  # Lambda 런타임에 포함. 테스트에서는 가짜 모듈로 대체

    return boto3


def get_param(name):
    """SSM SecureString 파라미터 조회 (성공한 값만 캐시)."""
    if name not in _param_cache:
        ssm = _boto3().client("ssm")
        _param_cache[name] = ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
    return _param_cache[name]


def rds_client():
    """계정 B의 역할로 전환한 RDS 클라이언트."""
    boto3 = _boto3()
    creds = boto3.client("sts").assume_role(
        RoleArn=TARGET_ROLE_ARN, RoleSessionName="loom-rds-control"
    )["Credentials"]
    return boto3.client(
        "rds",
        region_name=DB_REGION,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def db_status(rds):
    res = rds.describe_db_instances(DBInstanceIdentifier=DB_INSTANCE_ID)
    return res["DBInstances"][0]["DBInstanceStatus"]


def label(status):
    return STATUS_LABELS.get(status, f"🟡 {status}")


# ---------------------------------------------------------------- Mattermost 입출력
def respond(text, in_channel=False):
    """Function URL 응답 (Mattermost 슬래시 커맨드 응답 형식)."""
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {"response_type": "in_channel" if in_channel else "ephemeral", "text": text},
            ensure_ascii=False,
        ),
    }


def notify(text):
    """Incoming Webhook으로 채널에 알림."""
    body = json.dumps({"text": text}, ensure_ascii=False).encode()
    req = urllib.request.Request(
        get_param(WEBHOOK_PARAM), data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as res:
        res.read()


def parse_form(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    return {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}


def is_valid_token(form, headers):
    """요청 본문의 token 또는 'Authorization: Token <token>' 헤더를 상수 시간 비교."""
    expected = get_param(TOKEN_PARAM)
    candidates = [form.get("token", "")]
    auth = headers.get("authorization", "")
    if auth.lower().startswith("token "):
        candidates.append(auth[6:].strip())
    return any(c and hmac.compare_digest(c, expected) for c in candidates)


# ---------------------------------------------------------------- 명령 처리
def start_waiter(context, target, user):
    """완료 대기를 비동기 자기 호출로 넘긴다 (슬래시 커맨드 응답은 즉시 반환)."""
    _boto3().client("lambda").invoke(
        FunctionName=context.invoked_function_arn,
        InvocationType="Event",
        Payload=json.dumps(
            {"action": "wait", "target": target, "user": user, "requested_at": time.time()}
        ).encode(),
    )


def handle_command(form, context):
    words = form.get("text", "").strip().lower().split()
    cmd = words[0] if words else "help"
    user = form.get("user_name", "unknown")

    if cmd in ("help", "도움말"):
        return respond(HELP_TEXT)

    rds = rds_client()
    status = db_status(rds)

    if cmd == "status":
        return respond(f"@{user} 님의 상태 조회 — RDS `{DB_INSTANCE_ID}` : {label(status)}", in_channel=True)

    if cmd == "start":
        if status != "stopped":
            return respond(f"지금은 시작할 수 없습니다. 현재 상태: {label(status)}")
        rds.start_db_instance(DBInstanceIdentifier=DB_INSTANCE_ID)
        start_waiter(context, "available", user)
        return respond(
            f"▶️ @{user} 님이 RDS `{DB_INSTANCE_ID}` 시작을 요청했습니다. 완료되면 알려드릴게요 (보통 5~10분).",
            in_channel=True,
        )

    if cmd == "stop":
        if words[1:2] != ["confirm"]:
            return respond(
                "⚠️ RDS를 중지하면 백엔드가 DB를 사용할 수 없습니다.\n"
                "정말 중지하려면 `/rds stop confirm` 을 입력하세요."
            )
        if status != "available":
            return respond(f"지금은 중지할 수 없습니다. 현재 상태: {label(status)}")
        rds.stop_db_instance(DBInstanceIdentifier=DB_INSTANCE_ID)
        start_waiter(context, "stopped", user)
        return respond(
            f"⏹️ @{user} 님이 RDS `{DB_INSTANCE_ID}` 중지를 요청했습니다. 완료되면 알려드릴게요.\n"
            "⚠️ 중지된 RDS는 7일 후 AWS가 자동으로 다시 시작합니다.",
            in_channel=True,
        )

    return respond(f"알 수 없는 명령입니다: `{cmd}`\n\n{HELP_TEXT}")


def handle_wait(event, context):
    target, user = event["target"], event.get("user", "unknown")
    rds = rds_client()
    while True:
        status = db_status(rds)
        if status == target:
            elapsed = int(time.time() - event.get("requested_at", time.time()))
            verb = "시작" if target == "available" else "중지"
            notify(
                f"✅ RDS `{DB_INSTANCE_ID}` {verb} 완료 — {label(status)} "
                f"(요청: @{user}, {elapsed // 60}분 {elapsed % 60}초)"
            )
            return {"status": status}
        if context.get_remaining_time_in_millis() < DEADLINE_MARGIN_MS + POLL_INTERVAL_SECONDS * 1000:
            notify(
                f"⏳ RDS `{DB_INSTANCE_ID}` 가 아직 목표 상태({target})가 아닙니다. "
                f"현재: {label(status)} — `/rds status` 로 확인해 주세요."
            )
            return {"status": status, "timeout": True}
        time.sleep(POLL_INTERVAL_SECONDS)


# ---------------------------------------------------------------- 진입점
def lambda_handler(event, context):
    if event.get("action") == "wait":
        return handle_wait(event, context)

    # Function URL 요청 (Mattermost)
    if event.get("requestContext", {}).get("http", {}).get("method") != "POST":
        return {"statusCode": 405, "body": "Method Not Allowed"}

    form = parse_form(event)
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if not is_valid_token(form, headers):
        return {"statusCode": 401, "body": "Unauthorized"}
    if form.get("channel_id") != ALLOWED_CHANNEL_ID:
        return respond("🚫 이 채널에서는 `/rds` 명령을 사용할 수 없습니다.")

    try:
        return handle_command(form, context)
    except Exception as e:  # 사용자에게는 짧게, 상세는 CloudWatch 로그로
        print(f"ERROR: {type(e).__name__}: {e}")
        return respond(f"❌ 처리 중 오류가 발생했습니다: `{type(e).__name__}` (CloudWatch 로그 확인)")
