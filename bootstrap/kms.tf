# 환경별 고객 관리형 KMS 키. 백업 버킷 기본 암호화(SSE-KMS)와 앱 설정 파일(config/app.env)을 이 키로 암호화한다.
# envs/<env>는 별칭(alias/santacut-<env>)으로 키를 찾으므로 레포 변수가 따로 없다. 그래서 bootstrap을 먼저 적용해야 한다.
# 프로젝트가 짧아(2026-12-31 종료) 삭제 대기 기간을 최소인 7일로 둔다.

# 키 정책에 넣을 관리자 주체. SSO 같은 역할 세션이면 세션 ARN이 아니라 역할 ARN을 쓴다.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

data "aws_iam_policy_document" "kms" {
  for_each = local.environments

  # 계정 루트에 키를 맡겨 IAM 정책(apply 역할, 앱 사용자, 권한 경계)이 접근을 줄 수 있게 한다.
  # 이 문장이 있어야 키 정책을 잘못 고쳐도 키를 잃지 않는다.
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  # bootstrap을 적용하는 관리자에게 관리와 사용을 명시적으로 준다.
  statement {
    sid = "AllowBootstrapAdmin"
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_session_context.current.issuer_arn]
    }
  }
}

resource "aws_kms_key" "env" {
  for_each = local.environments

  description             = "산타컷 ${each.key} 백업 버킷과 앱 설정 파일 암호화 키"
  key_usage               = "ENCRYPT_DECRYPT"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms[each.key].json

  tags = {
    Environment = each.key
  }
}

resource "aws_kms_alias" "env" {
  for_each = local.environments

  name          = "alias/santacut-${each.key}"
  target_key_id = aws_kms_key.env[each.key].key_id
}
