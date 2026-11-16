# CI에서는 레포 변수(docs/operations.md 4단계)를 워크플로가 TF_VAR_*로 넘긴다. 로컬에서는 terraform.tfvars(커밋 금지)를 쓴다.
variable "domain_name" {
  description = "서비스 도메인(bootstrap의 domain_name과 같은 값). 도메인을 사기 전에는 비워 두고 고정 IP로 접속한다."
  type        = string
  default     = null
}

variable "bundle_id" {
  description = "Lightsail 번들(사양). nano_3_0은 512MB·월 5달러. 바꾸려면 docs/operations.md '인스턴스 교체' 절차를 따른다."
  type        = string
  default     = "nano_3_0"
}

variable "ssh_public_key" {
  description = "운영자와 배포 워크플로가 쓰는 SSH 공개 키."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "SSH(22) 접속을 허용할 운영자 CIDR 목록. 80/443은 이 값과 상관없이 모두에게 열려 있다."
  type        = list(string)
}

variable "bedrock_model_id" {
  description = "Claude Haiku 5.5 기반 모델 ID(anthropic.으로 시작). Global 추론 프로파일 ID는 모듈이 global.을 붙여 만든다."
  type        = string
}

variable "project_end_date" {
  description = "프로젝트 종료일(YYYY-MM-DD). 모든 리소스의 ExpiresOn 태그에 넣는다. 철거 절차는 docs/operations.md 13절."
  type        = string
  default     = "2026-12-31"
}
