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

  statement {
    sid       = "ReadWriteOwnBackupObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::santacut-${each.key}-backup-*/*"]
  }
}

resource "aws_iam_policy" "app_boundary" {
  for_each = local.environments

  name        = "santacut-${each.key}-app-boundary"
  description = "산타컷 ${each.key} 앱 IAM 사용자의 권한 경계: Bedrock 호출과 자기 환경 백업 버킷 읽기·쓰기만 허용"
  policy      = data.aws_iam_policy_document.app_boundary[each.key].json
}
