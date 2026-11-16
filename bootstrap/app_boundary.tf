# 앱 IAM 사용자(santacut-<env>-app)의 권한 상한. 환경마다 하나씩 두어 dev 앱 사용자가 운영 백업에 닿지 못하게 한다.
# apply 역할은 자기 환경 경계가 걸린 사용자만 만들고 정책을 붙일 수 있어, apply 역할을 탈취해도 앱 사용자를 관리자로 올릴 수 없다.
data "aws_iam_policy_document" "app_boundary" {
  for_each = local.environments

  statement {
    sid       = "InvokeBedrock"
    actions   = ["bedrock:InvokeModel"]
    resources = ["*"]
  }

  statement {
    sid       = "ListOwnBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::santacut-${each.key}-backup-*"]
  }

  # 설정(config/)과 백업(backups/)은 읽고, 쓰기는 백업 경로에만 한다.
  statement {
    sid       = "ReadOwnBackupObjects"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::santacut-${each.key}-backup-*/*"]
  }

  statement {
    sid       = "WriteOwnBackups"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::santacut-${each.key}-backup-*/backups/*"]
  }

  # 자기 환경 KMS 키로, S3를 거친 요청에서만 암호화·복호화한다. 키를 직접 불러 다른 데이터를 풀 수 없다.
  statement {
    sid       = "UseOwnKmsKeyThroughS3"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.env[each.key].arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.ap-northeast-2.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "app_boundary" {
  for_each = local.environments

  name = "santacut-${each.key}-app-boundary"
  # description을 바꾸면 정책이 교체되고, 사용자에 붙어 있으면 삭제가 실패한다. 범위 설명은 아래 정책 문서 주석에 둔다.
  description = "산타컷 ${each.key} 앱 IAM 사용자의 권한 경계: Bedrock 호출과 자기 환경 백업 버킷 읽기·쓰기만 허용"
  policy      = data.aws_iam_policy_document.app_boundary[each.key].json
}
