# 앱 레포(yooni9ue/santacut) 배포 워크플로가 맡는 역할. SSH(22)는 평소 운영자 CIDR에만 열려 있어서,
# 배포 동안만 GitHub 러너 IP에 22번을 열고 끝나면 닫는다. 자기 환경 인스턴스에만 허용한다.
# 남는 위험: 포트 번호는 IAM으로 제한할 수 없어 자기 환경 인스턴스의 다른 포트도 열 수 있다.
data "aws_iam_policy_document" "app_deploy_trust" {
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
      values   = ["${var.app_oidc_subject_repo}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "app_deploy" {
  for_each = local.environments

  name                 = "santacut-app-deploy-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.app_deploy_trust[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "app_deploy" {
  for_each = local.environments

  statement {
    sid       = "ReadInstance"
    actions   = ["lightsail:GetInstance", "lightsail:GetInstancePortStates"]
    resources = ["*"]
  }

  statement {
    sid       = "TemporarySshOnOwnInstance"
    actions   = ["lightsail:OpenInstancePublicPorts", "lightsail:CloseInstancePublicPorts"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [each.key]
    }
  }
}

resource "aws_iam_role_policy" "app_deploy" {
  for_each = local.environments

  name   = "temporary-ssh"
  role   = aws_iam_role.app_deploy[each.key].id
  policy = data.aws_iam_policy_document.app_deploy[each.key].json
}

output "app_deploy_role_arns" {
  description = "앱 레포 배포용 역할. 앱 레포의 각 GitHub Environment(dev, main) 변수 AWS_DEPLOY_ROLE_ARN에 넣는다."
  value       = { for env, role in aws_iam_role.app_deploy : env => role.arn }
}
