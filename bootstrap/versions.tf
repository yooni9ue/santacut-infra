# 계정에 한 번만 만드는 공용 리소스. 상태 버킷을 이 스택이 만들기 때문에 첫 적용은 로컬 상태로 하고,
# 직후 같은 상태 버킷으로 옮긴다(docs/operations.md 1단계). 이후 권한·예산을 바꿀 때 다시 적용한다.
terraform {
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "santacut"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
      ExpiresOn = var.project_end_date
    }
  }
}
