variable "environment" {
  description = "환경 이름(dev 또는 main). 리소스 이름 접두사와 Environment 태그에 쓴다."
  type        = string

  validation {
    condition     = contains(["dev", "main"], var.environment)
    error_message = "environment는 dev 또는 main이어야 한다."
  }
}

variable "availability_zone" {
  description = "Lightsail 인스턴스를 둘 가용 영역."
  type        = string
  default     = "ap-northeast-2a"
}

variable "bundle_id" {
  description = "Lightsail 번들(사양). nano_3_0은 512MB·2 vCPU·20GB·월 5달러(서울). JVM 힙을 제한해야 한다(docs/operations.md 6단계). 값을 바꿔도 제자리 변경이 되지 않고 재생성이 필요해 prevent_destroy에 막힌다. 사양 변경은 docs/operations.md '인스턴스 교체' 절차를 따른다."
  type        = string
  default     = "nano_3_0"
}

variable "blueprint_id" {
  description = "Lightsail OS 이미지. 목록: aws lightsail get-blueprints"
  type        = string
  default     = "ubuntu_24_04"
}

variable "ssh_public_key" {
  description = "운영자와 배포 워크플로가 접속할 SSH 공개 키(OpenSSH 형식)."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "SSH(22) 접속을 허용할 운영자 IPv4 CIDR 목록. 접두사 길이는 /24 이상이어야 한다."
  type        = list(string)

  validation {
    condition = length(var.ssh_allowed_cidrs) > 0 && alltrue([
      for c in var.ssh_allowed_cidrs :
      can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c)) && try(tonumber(split("/", c)[1]) >= 24, false)
    ])
    error_message = "ssh_allowed_cidrs는 비어 있으면 안 되고, 모든 항목이 /24 이상 접두사의 IPv4 CIDR이어야 한다."
  }
}

variable "snapshot_time_utc" {
  description = "Lightsail 자동 스냅숏 시각(UTC, HH:00). 기본값 18:00은 한국 시간 새벽 3시다."
  type        = string
  default     = "18:00"
}

variable "zone_id" {
  description = "앱 도메인 레코드를 만들 Route 53 호스팅 영역 ID. 도메인이 없으면 null."
  type        = string
  default     = null
}

variable "fqdn" {
  description = "이 환경의 접속 도메인(예: santacut.kr, dev.santacut.kr). null이면 DNS 레코드를 만들지 않는다."
  type        = string
  default     = null

  validation {
    condition     = var.fqdn == null || var.zone_id != null
    error_message = "fqdn을 넣으면 zone_id도 넣어야 한다."
  }
}

variable "backup_retention_days" {
  description = "S3 백업 객체가 최신 버전으로 남는 일수. 지나면 이전 버전으로 바뀐다."
  type        = number
  default     = 30
}

variable "backup_noncurrent_days" {
  description = "이전 버전이 된 백업 객체를 영구 삭제하기까지의 일수. 백업이 실제로 남는 최대 기간은 backup_retention_days + 이 값이다."
  type        = number
  default     = 7
}

variable "bedrock_model_id" {
  description = "Claude Haiku 5.5 기반 모델 ID(anthropic.으로 시작). Global 추론 프로파일 ID는 앞에 global.을 붙여 만든다."
  type        = string

  validation {
    condition     = startswith(var.bedrock_model_id, "anthropic.")
    error_message = "bedrock_model_id는 anthropic.으로 시작하는 기반 모델 ID여야 한다(global. 접두사 없이)."
  }
}
