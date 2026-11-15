variable "infra_oidc_subject_repo" {
  description = <<-EOT
    santacut-infra 레포의 GitHub OIDC sub 앞부분. 2026-07-15 이후 만든 레포는 불변 ID 형식
    (repo:OWNER@OWNER_ID/REPO@REPO_ID)을 쓴다. 기본값은 2026-11-16에 GitHub API로 확인한 조직·레포 ID로 만든 값이다(docs/operations.md 4단계).
  EOT
  type        = string
  default     = "repo:yooni9ue@356647612/santacut-infra@1458963706"
}

variable "app_oidc_subject_repo" {
  description = "앱 레포(yooni9ue/santacut)의 GitHub OIDC sub 앞부분. 형식은 infra_oidc_subject_repo와 같다."
  type        = string
  default     = "repo:yooni9ue@356647612/santacut@1457838283"
}

variable "domain_name" {
  description = "가비아에서 구매한 서비스 도메인(예: santacut.kr). Route 53 호스팅 영역을 만든다."
  type        = string
}

variable "monthly_budget_usd" {
  description = "계정 전체 월 비용 알림 기준(USD). 근거는 README '예상 월 비용' 표."
  type        = number
  default     = 40
}

variable "bedrock_budget_usd" {
  description = "Bedrock 비용만 따로 보는 월 예산(USD)."
  type        = number
  default     = 10
}

variable "bedrock_cost_service_names" {
  description = "Cost Explorer에서 Bedrock 모델 비용이 잡히는 서비스 이름 목록. 첫 호출 다음 날 Cost Explorer에서 실제 이름을 확인해 맞춘다."
  type        = list(string)
  default     = ["Amazon Bedrock"]
}

variable "enable_bedrock_stop" {
  description = "Bedrock 예산을 실제로 100% 넘기면 두 앱 IAM 사용자에게 Bedrock 거부 정책을 자동으로 붙인다. 두 환경을 적용해 앱 사용자가 생긴 뒤 true로 켠다."
  type        = bool
  default     = false
}

variable "bedrock_stop_environments" {
  description = "예산 초과 시 Bedrock 거부 정책을 붙일 앱 사용자의 환경 목록. dev를 내리면 여기서 빼고 bootstrap을 다시 적용한다."
  type        = list(string)
  default     = ["dev", "main"]

  validation {
    condition     = alltrue([for e in var.bedrock_stop_environments : contains(["dev", "main"], e)])
    error_message = "bedrock_stop_environments에는 dev, main만 넣을 수 있다."
  }
}

variable "budget_alert_emails" {
  description = "비용 알림을 받을 이메일 목록."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "비용 알림을 받을 이메일을 하나 이상 넣어야 한다."
  }
}
