# CI에서는 레포 변수(docs/operations.md 4단계)를 워크플로가 TF_VAR_*로 넘긴다. 로컬에서는 terraform.tfvars(커밋 금지)를 쓴다.
variable "domain_name" {
  description = "서비스 도메인(bootstrap의 domain_name과 같은 값)."
  type        = string
}

variable "bundle_id" {
  description = "Lightsail 번들(사양)."
  type        = string
  default     = "small_3_0"
}

variable "ssh_public_key" {
  description = "운영자와 배포 워크플로가 쓰는 SSH 공개 키."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "SSH 접속을 허용할 운영자 CIDR 목록."
  type        = list(string)
}

variable "bedrock_model_id" {
  description = "Claude Haiku 5.5 기반 모델 ID(anthropic.으로 시작). Global 추론 프로파일 ID는 모듈이 global.을 붙여 만든다."
  type        = string
}
