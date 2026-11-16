# 운영 환경. 접속 도메인은 서비스 도메인 그 자체다.
terraform {
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket은 계정 ID가 들어가 있어 init 때 넘긴다: -backend-config="bucket=<bootstrap state_bucket 출력값>"
  backend "s3" {
    key          = "envs/main/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "santacut"
      Environment = "main"
      ManagedBy   = "terraform"
      ExpiresOn   = var.project_end_date
    }
  }
}

locals {
  # CI는 레포 변수 DOMAIN_NAME이 없으면 빈 문자열을 넘긴다. 빈 값은 도메인 없음(고정 IP 접속)으로 본다.
  domain = var.domain_name == null ? null : (trimspace(var.domain_name) == "" ? null : lower(trimspace(var.domain_name)))
}

# bootstrap이 domain_name으로 만든 호스팅 영역. 도메인이 없으면 찾지 않는다.
data "aws_route53_zone" "main" {
  count = local.domain == null ? 0 : 1

  name = local.domain
}

# bootstrap kms.tf가 만든 이 환경 키. 별칭으로 찾으므로 레포 변수가 필요 없다. bootstrap을 먼저 적용해야 한다.
data "aws_kms_alias" "env" {
  name = "alias/santacut-main"
}

module "app" {
  source = "../../modules/santacut_app"

  environment       = "main"
  fqdn              = local.domain == null ? null : "api.${local.domain}"
  zone_id           = one(data.aws_route53_zone.main[*].zone_id)
  bundle_id         = var.bundle_id
  ssh_public_key    = var.ssh_public_key
  ssh_allowed_cidrs = var.ssh_allowed_cidrs

  kms_key_arn = data.aws_kms_alias.env.target_key_arn
}
