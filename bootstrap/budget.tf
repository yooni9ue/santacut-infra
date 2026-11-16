# 계정 전체 월 비용 알림. 청구 데이터는 하루 단위로 늦게 반영되고, 예측 알림은 사용 이력이 약 5주 쌓여야 울린다.
resource "aws_budgets_budget" "monthly" {
  name         = "santacut-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 프로젝트 종료 뒤 1월 청구분까지만 본다.
  time_period_end = var.budget_end

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

# AI 비용만 따로 본다. 고정비에 묻히지 않게 작은 금액으로 둔다.
# 1차 방어는 앱의 일일 토큰 한도이고, 이 예산은 하루 늦게 반응하는 2차 방어다.
resource "aws_budgets_budget" "bedrock" {
  name         = "santacut-bedrock"
  budget_type  = "COST"
  limit_amount = tostring(var.bedrock_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 프로젝트 종료 뒤 1월 청구분까지만 본다.
  time_period_end = var.budget_end

  cost_filter {
    name   = "Service"
    values = var.bedrock_cost_service_names
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

# ---------------------------------------------------------------------------
# Bedrock 예산 100% 초과 시 앱 사용자에게 Bedrock 거부 정책을 자동으로 붙인다(enable_bedrock_stop).
# 해제 절차: docs/operations.md 10절.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deny_bedrock" {
  statement {
    sid       = "StopBedrockOverBudget"
    effect    = "Deny"
    actions   = ["bedrock:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deny_bedrock" {
  count = var.enable_bedrock_stop ? 1 : 0

  name        = "santacut-deny-bedrock"
  description = "Bedrock 예산 초과 시 앱 사용자에게 자동으로 붙는 거부 정책"
  policy      = data.aws_iam_policy_document.deny_bedrock.json
}

data "aws_iam_policy_document" "budget_action_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "budget_action" {
  count = var.enable_bedrock_stop ? 1 : 0

  name               = "santacut-budget-action"
  assume_role_policy = data.aws_iam_policy_document.budget_action_trust.json
}

data "aws_iam_policy_document" "budget_action" {
  count = var.enable_bedrock_stop ? 1 : 0

  statement {
    actions   = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
    resources = [for env in var.bedrock_stop_environments : "arn:aws:iam::${local.account_id}:user/santacut/santacut-${env}-app"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [aws_iam_policy.deny_bedrock[0].arn]
    }
  }
}

resource "aws_iam_role_policy" "budget_action" {
  count = var.enable_bedrock_stop ? 1 : 0

  name   = "attach-deny-bedrock"
  role   = aws_iam_role.budget_action[0].id
  policy = data.aws_iam_policy_document.budget_action[0].json
}

resource "aws_budgets_budget_action" "stop_bedrock" {
  count = var.enable_bedrock_stop ? 1 : 0

  budget_name        = aws_budgets_budget.bedrock.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action[0].arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.deny_bedrock[0].arn
      users      = [for env in var.bedrock_stop_environments : "santacut-${env}-app"]
    }
  }

  subscriber {
    address           = var.budget_alert_emails[0]
    subscription_type = "EMAIL"
  }
}
