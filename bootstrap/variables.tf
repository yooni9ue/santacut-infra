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
  description = "가비아에서 구매한 서비스 도메인(예: santacut.kr). 넣으면 Route 53 호스팅 영역을 만든다. 도메인을 사기 전에는 비워 둔다(null 또는 빈 문자열)."
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "계정 전체 월 비용 알림 기준(USD). 근거는 README '예상 월 비용' 표."
  type        = number
  default     = 20
}

variable "budget_alert_emails" {
  description = "비용 알림을 받을 이메일 목록."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "비용 알림을 받을 이메일을 하나 이상 넣어야 한다."
  }
}

variable "project_end_date" {
  description = "프로젝트 종료일(YYYY-MM-DD). 모든 리소스의 ExpiresOn 태그에 넣는다. 철거 절차는 docs/operations.md 13절."
  type        = string
  default     = "2026-12-31"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.project_end_date))
    error_message = "project_end_date는 YYYY-MM-DD 형식이어야 한다."
  }
}

variable "budget_end" {
  description = "예산 알림이 끝나는 시각(YYYY-MM-DD_HH:MM). 12월 사용분이 1월에 청구되므로 종료일보다 한 달 뒤로 둔다."
  type        = string
  default     = "2027-01-31_00:00"
}
