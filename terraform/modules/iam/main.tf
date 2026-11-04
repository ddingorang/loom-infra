# 액세스 키는 여기서 만들지 않습니다(secret이 state에 평문으로 남기 때문).
# apply 후 `aws iam create-access-key --user-name <이름>`으로 발급해 Ansible vault에 넣으세요.

# ---------- CI: Jenkins ECR push / EC2 ECR pull / 프론트 Amplify 배포 ----------
resource "aws_iam_user" "ci" {
  name = "${var.name_prefix}-ci"
}

data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = var.ecr_repository_arns
  }

  statement {
    sid = "AmplifyManualDeploy"
    actions = [
      "amplify:GetApp",
      "amplify:GetBranch",
      "amplify:CreateDeployment",
      "amplify:StartDeployment",
      "amplify:GetJob",
      "amplify:ListJobs",
    ]
    resources = [var.amplify_app_arn, "${var.amplify_app_arn}/*"]
  }
}

resource "aws_iam_user_policy" "ci" {
  name   = "ci-deploy"
  user   = aws_iam_user.ci.name
  policy = data.aws_iam_policy_document.ci.json
}

# ---------- App: Spring 컨테이너의 이미지 업로드/삭제 ----------
resource "aws_iam_user" "app" {
  name = "${var.name_prefix}-app"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ListImageBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.image_bucket_arn]
  }

  statement {
    sid       = "ImageObjectsRW"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${var.image_bucket_arn}/*"]
  }
}

resource "aws_iam_user_policy" "app" {
  name   = "image-bucket-rw"
  user   = aws_iam_user.app.name
  policy = data.aws_iam_policy_document.app.json
}
