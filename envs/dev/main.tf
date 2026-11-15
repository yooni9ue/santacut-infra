# dev 환경. 운영(main)과 같은 모듈을 쓰고 접속 도메인만 dev 하위 도메인이다.
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
    key          = "envs/dev/terraform.tfstate"
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
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_route53_zone" "main" {
  name = var.domain_name
}

module "app" {
  source = "../../modules/santacut_app"

  environment       = "dev"
  fqdn              = "dev.${var.domain_name}"
  zone_id           = data.aws_route53_zone.main.zone_id
  bundle_id         = var.bundle_id
  ssh_public_key    = var.ssh_public_key
  ssh_allowed_cidrs = var.ssh_allowed_cidrs

  bedrock_model_id = var.bedrock_model_id
}
