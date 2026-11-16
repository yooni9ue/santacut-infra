# Lightsail 인스턴스는 IAM 역할을 쓸 수 없어 앱 전용 IAM 사용자를 둔다.
# 액세스 키는 상태 파일에 남지 않도록 Terraform이 아니라 사람이 발급해 인스턴스에 직접 쓴다(docs/operations.md 6절).
locals {
  inference_profile_id  = "global.${var.bedrock_model_id}"
  inference_profile_arn = "arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${local.inference_profile_id}"

  # bootstrap/app_boundary.tf가 환경마다 만드는 권한 경계. 인라인 정책이 무엇이든 권한 상한이 여기서 고정된다.
  app_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/santacut-${var.environment}-app-boundary"
}

resource "aws_iam_user" "app" {
  name                 = "${local.name}-app"
  path                 = "/santacut/"
  permissions_boundary = local.app_boundary_arn
}

data "aws_iam_policy_document" "app" {
  # 프로파일 평가에는 bedrock:InferenceProfileArn 키가 없으므로 조건을 걸지 않는다.
  statement {
    sid       = "InvokeScoreModelProfile"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.inference_profile_arn]
  }

  # Global 교차 리전 추론은 요청을 다른 리전의 기반 모델로 보낸다. 이 프로파일을 거친 호출만 허용한다.
  # 리전 없는 기반 모델 ARN은 Global 추론에 필요하다.
  statement {
    sid     = "InvokeFoundationModelThroughProfile"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${var.bedrock_model_id}",
      "arn:aws:bedrock:::foundation-model/${var.bedrock_model_id}",
    ]

    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = [local.inference_profile_arn]
    }
  }

  statement {
    sid       = "ListBackupBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backup.arn]
  }

  # 앱 설정(config/)은 읽기만 한다. 앱 키가 유출돼도 설정을 바꿔치기할 수 없다.
  statement {
    sid       = "ReadConfigObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.backup.arn}/config/*"]
  }

  # 백업 업로드와 복구용 읽기만 허용한다. 삭제 권한은 주지 않고 만료는 수명 주기 규칙이 맡는다.
  statement {
    sid       = "ReadWriteBackupObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.backup.arn}/backups/*"]
  }

  # SSE-KMS 객체를 읽고 쓰려면 이 환경 키가 필요하다. S3를 거친 요청만 허용해 키를 직접 쓰지 못하게 한다.
  statement {
    sid       = "UseEnvKmsKeyThroughS3"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_user_policy" "app" {
  name   = "${local.name}-app"
  user   = aws_iam_user.app.name
  policy = data.aws_iam_policy_document.app.json
}
