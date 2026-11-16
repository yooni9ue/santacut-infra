# GitHub Actions가 장기 액세스 키 없이 OIDC로 역할을 맡는다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  environments = toset(["dev", "main"])
  state_arn    = aws_s3_bucket.state.arn
  account_id   = data.aws_caller_identity.current.account_id

  # 환경별로 바꿀 수 있는 DNS 레코드 이름(Route 53 정규화 형식: 소문자, 끝 점 없음). 도메인이 없으면 비어 있다.
  record_names = local.domain == null ? {} : {
    dev  = "dev.${local.domain}"
    main = local.domain
  }

  # Terraform 모듈이 쓰는 Lightsail 액션만 허용한다. 로드 밸런서·DB·컨테이너처럼 월 고정비가 드는
  # 리소스는 만들 수 없다. 첫 apply에서 AccessDenied가 나면 그 액션만 여기에 더한다.
  # 읽기는 ReadOnlyAccess가 준다. lightsail:Get*을 주면 SSH 임시 자격 증명(GetInstanceAccessDetails)까지 열린다.
  lightsail_apply_actions = [
    "lightsail:CreateInstances",
    "lightsail:DeleteInstance",
    "lightsail:ImportKeyPair",
    "lightsail:DeleteKeyPair",
    "lightsail:AllocateStaticIp",
    "lightsail:ReleaseStaticIp",
    "lightsail:AttachStaticIp",
    "lightsail:DetachStaticIp",
    "lightsail:PutInstancePublicPorts",
    "lightsail:CloseInstancePublicPorts",
    "lightsail:EnableAddOn",
    "lightsail:DisableAddOn",
    "lightsail:TagResource",
    "lightsail:UntagResource",
  ]

  # 다른 환경 리소스(인스턴스, 키 페어)에 하면 안 되는 액션. Environment 태그가 자기 환경이 아니면 거부한다.
  # IAM으로 환경을 가를 수 없어 남는 위험(docs/operations.md 4단계에 기록):
  # - EnableAddOn/DisableAddOn은 리소스 타입이 없어 태그 조건이 평가되지 않는다(자동 스냅숏 끄기).
  # - 고정 IP는 태그를 지원하지 않아 Attach/Detach/ReleaseStaticIp를 환경별로 막을 수 없다.
  lightsail_cross_env_denied_actions = [
    "lightsail:DeleteInstance",
    "lightsail:StopInstance",
    "lightsail:RebootInstance",
    "lightsail:PutInstancePublicPorts",
    "lightsail:OpenInstancePublicPorts",
    "lightsail:CloseInstancePublicPorts",
    "lightsail:CreateInstanceSnapshot",
    "lightsail:DeleteKeyPair",
    "lightsail:TagResource",
    "lightsail:UntagResource",
  ]
}

# 어떤 Terraform 역할도 인스턴스 접속 자격 증명을 얻지 못하게 한다.
data "aws_iam_policy_document" "deny_instance_access" {
  statement {
    sid       = "DenyInstanceAccessCredentials"
    effect    = "Deny"
    actions   = ["lightsail:GetInstanceAccessDetails", "lightsail:DownloadDefaultKeyPair"]
    resources = ["*"]
  }
}

# Terraform 역할 공통: 백업 객체와 config/app.env는 읽지 않는다(ReadOnlyAccess의 s3:Get*을 상쇄).
# 객체가 KMS로 암호화돼 있고 이 역할들에는 kms:Decrypt가 없어 이중으로 막힌다.
data "aws_iam_policy_document" "deny_backup_objects" {
  statement {
    sid       = "DenyBackupObjectRead"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["arn:aws:s3:::santacut-*-backup-*/*"]
  }
}

# ---------------------------------------------------------------------------
# plan 역할: PR과 main 병합 후 운영 plan에서 쓴다. 읽기 전용 + 상태 읽기 + 잠금 파일 쓰기만 허용한다.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${var.infra_oidc_subject_repo}:pull_request",
        "${var.infra_oidc_subject_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "santacut-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  source_policy_documents = [
    data.aws_iam_policy_document.deny_backup_objects.json,
    data.aws_iam_policy_document.deny_instance_access.json,
  ]

  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = [local.state_arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${local.state_arn}/envs/*"]
  }

  statement {
    sid       = "WriteLockFile"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_arn}/envs/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# ---------------------------------------------------------------------------
# apply 역할: 환경마다 하나. GitHub Environment(dev, main)에서만 맡을 수 있다.
# 자기 상태 키, 자기 접두사 버킷과 앱 사용자, 자기 DNS 레코드, 자기 Environment 태그의 인스턴스만 바꾼다.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "apply_trust" {
  for_each = local.environments

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.infra_oidc_subject_repo}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "apply" {
  for_each = local.environments

  name                 = "santacut-terraform-apply-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust[each.key].json
  max_session_duration = 3600
}

# refresh에 필요한 읽기 권한.
resource "aws_iam_role_policy_attachment" "apply_read_only" {
  for_each = local.environments

  role       = aws_iam_role.apply[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "apply" {
  for_each = local.environments

  source_policy_documents = [
    data.aws_iam_policy_document.deny_backup_objects.json,
    data.aws_iam_policy_document.deny_instance_access.json,
  ]

  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = [local.state_arn]
  }

  statement {
    sid       = "ReadWriteOwnState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_arn}/envs/${each.key}/*"]
  }

  statement {
    sid       = "ManageLightsail"
    actions   = local.lightsail_apply_actions
    resources = ["*"]
  }

  # Lightsail ARN은 이름이 아니라 내부 ID라 접두사로 좁힐 수 없어 Environment 태그로 환경을 가른다.
  # 태그 조건을 지원하지 않는 액션에서는 키가 비어 있으므로 Null 검사로 그 경우를 거부 대상에서 뺀다.
  statement {
    sid       = "DenyOtherEnvironmentInstances"
    effect    = "Deny"
    actions   = local.lightsail_cross_env_denied_actions
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Environment"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [each.key]
    }
  }

  # 인스턴스는 자기 Environment 태그를 달고서만 만든다(태그 없는 생성도 거부).
  # ImportKeyPair는 요청에 태그가 없어 조건을 걸 수 없다. 프로바이더가 가져온 뒤 TagResource로 태그를 다는데,
  # 그 태그 값은 아래 DenyRetaggingToOtherEnvironment가 자기 환경으로만 허용한다.
  statement {
    sid       = "DenyCreatingWithoutOwnEnvironmentTag"
    effect    = "Deny"
    actions   = ["lightsail:CreateInstances"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.key]
    }
  }

  statement {
    sid       = "DenyRetaggingToOtherEnvironment"
    effect    = "Deny"
    actions   = ["lightsail:TagResource"]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/Environment"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.key]
    }
  }

  statement {
    sid     = "ManageOwnBuckets"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::santacut-${each.key}-*",
      "arn:aws:s3:::santacut-${each.key}-*/*",
    ]
  }

  # 백업 버킷 기본 암호화(SSE-KMS)에 넣을 자기 환경 키만 조회한다. 복호화 권한은 주지 않는다.
  # 키 조회(ListAliases, DescribeKey)는 ReadOnlyAccess로도 되지만, 필요한 권한을 여기에 명시해 둔다.
  statement {
    sid       = "DescribeOwnKmsKey"
    actions   = ["kms:DescribeKey"]
    resources = [aws_kms_key.env[each.key].arn]
  }

  statement {
    sid = "ManageOwnAppUser"
    actions = [
      "iam:DeleteUser",
      "iam:GetUser",
      "iam:TagUser",
      "iam:UntagUser",
      "iam:GetUserPolicy",
      "iam:DeleteUserPolicy",
      "iam:ListUserPolicies",
      "iam:ListAttachedUserPolicies",
      "iam:ListGroupsForUser",
      "iam:ListAccessKeys",
    ]
    resources = ["arn:aws:iam::${local.account_id}:user/santacut/santacut-${each.key}-*"]
  }

  # 사용자 생성과 정책 부착은 santacut-app-boundary 경계가 걸린 경우에만 허용한다.
  statement {
    sid = "ManageOwnAppUserWithinBoundary"
    actions = [
      "iam:CreateUser",
      "iam:PutUserPolicy",
      "iam:PutUserPermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.account_id}:user/santacut/santacut-${each.key}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.app_boundary[each.key].arn]
    }
  }

  # 도메인이 있을 때만 자기 레코드를 바꿀 수 있다. 호스팅 영역이 없으면 이 문장도 없다.
  dynamic "statement" {
    for_each = aws_route53_zone.main

    content {
      sid       = "ManageOwnRecord"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = [statement.value.arn]

      condition {
        test     = "ForAllValues:StringEquals"
        variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
        values   = [local.record_names[each.key]]
      }

      condition {
        test     = "ForAllValues:StringEquals"
        variable = "route53:ChangeResourceRecordSetsRecordTypes"
        values   = ["A"]
      }
    }
  }

  statement {
    sid       = "WatchRecordChanges"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  for_each = local.environments

  name   = "terraform-apply"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.apply[each.key].json
}
