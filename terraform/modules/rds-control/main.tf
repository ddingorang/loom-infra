# Mattermost 슬래시 커맨드(/rds) → Lambda Function URL → (AssumeRole) → 계정 B의 RDS 시작/중지/조회
#
# 비밀값(커맨드 토큰, Incoming Webhook URL)은 Terraform state에 남지 않도록 여기서 만들지 않고,
# apply 후 `aws ssm put-parameter`로 직접 넣습니다. (README 참고)

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  function_arn = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}"
  param_arns = [
    for p in [var.token_param_name, var.webhook_param_name] :
    "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${p}"
  ]
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/.build/rds-control.zip"
}

# ---------- 실행 역할 ----------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.function_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "AssumeDbAccountRole"
    actions   = ["sts:AssumeRole"]
    resources = [var.target_role_arn]
  }

  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParameter"]
    resources = local.param_arns
  }

  # SecureString 복호화 (기본 aws/ssm 키, SSM 경유 호출로만 제한)
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # 완료 대기를 위한 비동기 자기 호출
  statement {
    sid       = "InvokeSelf"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.function_arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "rds-control"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ---------- Lambda ----------
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "this" {
  function_name    = var.function_name
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  memory_size      = 128
  # 완료 대기(RDS 시작 5~10분)를 위해 최대치. Function URL 요청 자체는 즉시 응답합니다.
  timeout = 900

  environment {
    variables = {
      DB_INSTANCE_ID     = var.db_instance_identifier
      DB_REGION          = var.db_region
      TARGET_ROLE_ARN    = var.target_role_arn
      ALLOWED_CHANNEL_ID = var.allowed_channel_id
      TOKEN_PARAM        = var.token_param_name
      WEBHOOK_PARAM      = var.webhook_param_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy_attachment.logs]
}

# 비동기 자기 호출은 재시도하지 않음 (중복 알림 방지)
resource "aws_lambda_function_event_invoke_config" "this" {
  function_name          = aws_lambda_function.this.function_name
  maximum_retry_attempts = 0
}

# ---------- Function URL (Mattermost가 호출) ----------
# Mattermost는 SigV4 서명을 못 하므로 NONE. 대신 함수 안에서 커맨드 토큰 + 채널을 검증합니다.
resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.this.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# 2025년 10월 이후 공개 Function URL은 InvokeFunction 권한도 필요 (Function URL 경유 호출로만 제한)
resource "aws_lambda_permission" "url_invoke" {
  statement_id             = "AllowPublicInvokeViaFunctionUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.this.function_name
  principal                = "*"
  invoked_via_function_url = true
}
