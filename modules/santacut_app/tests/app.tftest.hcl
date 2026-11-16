# AWS 자격 증명 없이 모듈 규칙을 검사한다: terraform -chdir=modules/santacut_app test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-northeast-2"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::santacut-dev-backup-123456789012"
    }
  }

  mock_resource "aws_lightsail_static_ip" {
    defaults = {
      ip_address = "203.0.113.20"
    }
  }
}

variables {
  environment       = "dev"
  fqdn              = "dev.santacut.example"
  zone_id           = "Z0000000000000000000"
  ssh_public_key    = "ssh-ed25519 AAAATEST santacut-test"
  ssh_allowed_cidrs = ["203.0.113.10/32"]
  bedrock_model_id  = "anthropic.claude-haiku-test"
  kms_key_arn       = "arn:aws:kms:ap-northeast-2:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
}

run "names_follow_environment_prefix" {
  command = apply

  assert {
    condition     = aws_lightsail_instance.app.name == "santacut-dev-app"
    error_message = "인스턴스 이름은 santacut-<env>-app이어야 한다."
  }

  assert {
    condition     = aws_s3_bucket.backup.bucket == "santacut-dev-backup-123456789012"
    error_message = "백업 버킷 이름은 santacut-<env>-backup-<계정 ID>여야 한다."
  }

  assert {
    condition     = aws_iam_user.app.name == "santacut-dev-app" && aws_iam_user.app.path == "/santacut/"
    error_message = "앱 IAM 사용자는 /santacut/ 경로의 santacut-<env>-app이어야 한다."
  }
}

run "app_user_has_permissions_boundary" {
  command = apply

  assert {
    condition     = aws_iam_user.app.permissions_boundary == "arn:aws:iam::123456789012:policy/santacut-dev-app-boundary"
    error_message = "앱 IAM 사용자에는 santacut-dev-app-boundary 권한 경계가 걸려 있어야 한다."
  }
}

run "inference_profile_is_derived_from_model_id" {
  command = plan

  assert {
    condition     = local.inference_profile_arn == "arn:aws:bedrock:ap-northeast-2:123456789012:inference-profile/global.anthropic.claude-haiku-test"
    error_message = "추론 프로파일 ARN은 global.<기반 모델 ID>여야 한다."
  }
}

run "dns_points_at_static_ip" {
  command = apply

  assert {
    condition     = aws_route53_record.app[0].records == toset(["203.0.113.20"]) && aws_route53_record.app[0].type == "A"
    error_message = "도메인 A 레코드는 고정 IP를 가리켜야 한다."
  }

  assert {
    condition     = output.app_url == "https://dev.santacut.example"
    error_message = "도메인이 있으면 접속 주소는 https://<fqdn>이어야 한다."
  }
}

run "no_domain_uses_static_ip_without_dns" {
  command = apply

  variables {
    fqdn    = null
    zone_id = null
  }

  assert {
    condition     = length(aws_route53_record.app) == 0
    error_message = "도메인이 없으면 Route 53 레코드를 만들지 않아야 한다."
  }

  assert {
    condition     = output.fqdn == null
    error_message = "도메인이 없으면 fqdn 출력은 null이어야 한다."
  }

  assert {
    condition     = output.app_url == "http://203.0.113.20" && output.static_ip == "203.0.113.20"
    error_message = "도메인이 없으면 접속 주소는 http://<고정 IP>여야 한다."
  }
}

run "fqdn_without_zone_is_rejected" {
  command = plan

  variables {
    zone_id = null
  }

  expect_failures = [var.fqdn]
}

run "default_bundle_is_cheapest" {
  command = plan

  assert {
    condition     = aws_lightsail_instance.app.bundle_id == "nano_3_0"
    error_message = "기본 번들은 월 5달러 nano_3_0이어야 한다."
  }
}

run "only_ssh_http_https_are_open_on_ipv4" {
  command = apply

  assert {
    condition     = aws_lightsail_instance.app.ip_address_type == "ipv4"
    error_message = "IPv6 방화벽 노출을 막기 위해 인스턴스는 IPv4 전용이어야 한다."
  }

  assert {
    condition     = toset([for p in aws_lightsail_instance_public_ports.app.port_info : p.from_port]) == toset([22, 80, 443])
    error_message = "공개 포트는 22, 80, 443뿐이어야 한다."
  }

  assert {
    condition     = alltrue([for p in aws_lightsail_instance_public_ports.app.port_info : p.cidrs == toset(["203.0.113.10/32"]) if p.from_port == 22])
    error_message = "SSH는 ssh_allowed_cidrs에만 열려야 한다."
  }
}

run "snapshots_and_backups_are_on" {
  command = apply

  assert {
    condition     = one(aws_lightsail_instance.app.add_on).status == "Enabled"
    error_message = "자동 스냅숏이 켜져 있어야 한다."
  }

  assert {
    condition     = aws_s3_bucket_versioning.backup.versioning_configuration[0].status == "Enabled"
    error_message = "백업 버킷 버전 관리가 켜져 있어야 한다."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.backup.block_public_acls && aws_s3_bucket_public_access_block.backup.restrict_public_buckets
    error_message = "백업 버킷 공개 접근이 막혀 있어야 한다."
  }
}

run "ssh_open_to_world_is_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

run "ssh_split_world_cidrs_are_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["0.0.0.0/1", "128.0.0.0/1"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

run "ssh_ipv6_cidr_is_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["2001:db8::/64"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

run "profile_id_instead_of_model_id_is_rejected" {
  command = plan

  variables {
    bedrock_model_id = "global.anthropic.claude-haiku-test"
  }

  expect_failures = [var.bedrock_model_id]
}

run "unknown_environment_is_rejected" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "backup_bucket_uses_env_kms_key" {
  command = apply

  assert {
    condition = length(aws_s3_bucket_server_side_encryption_configuration.backup.rule) == 1 && alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.backup.rule :
      one(r.apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" &&
      one(r.apply_server_side_encryption_by_default).kms_master_key_id == var.kms_key_arn &&
      r.bucket_key_enabled == true
    ])
    error_message = "백업 버킷은 이 환경 KMS 키로 SSE-KMS 기본 암호화하고 버킷 키를 써야 한다."
  }

  assert {
    condition = length([
      for st in data.aws_iam_policy_document.backup_tls_only.statement : st
      if st.effect == "Deny" && contains(st.actions, "s3:PutObject") &&
      anytrue([for c in st.condition : c.variable == "s3:x-amz-server-side-encryption" && c.values == tolist(["aws:kms"])])
    ]) == 1
    error_message = "버킷 정책은 aws:kms 없이 올리는 PutObject를 거부해야 한다."
  }

  assert {
    condition = length([
      for st in data.aws_iam_policy_document.backup_tls_only.statement : st
      if st.effect == "Deny" && contains(st.actions, "s3:PutObject") &&
      anytrue([for c in st.condition : c.variable == "s3:x-amz-server-side-encryption-aws-kms-key-id" && c.values == tolist([var.kms_key_arn])])
    ]) == 1
    error_message = "버킷 정책은 이 환경 키가 아닌 KMS 키로 올리는 PutObject를 거부해야 한다."
  }
}

run "lifecycle_expires_only_backups_prefix" {
  command = apply

  assert {
    condition = length(aws_s3_bucket_lifecycle_configuration.backup.rule) == 1 && alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.backup.rule :
      r.status == "Enabled" && one(r.filter).prefix == "backups/"
    ])
    error_message = "수명 주기 규칙은 backups/ 접두사에만 걸려야 한다(config/는 만료되면 안 된다)."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.backup.rule :
      one(r.expiration).days == 14 && one(r.noncurrent_version_expiration).noncurrent_days == 7
    ])
    error_message = "백업은 14일 뒤 이전 버전이 되고, 그로부터 7일 뒤 삭제되어야 한다."
  }
}

run "app_policy_is_limited_to_env_kms_key_and_prefixes" {
  command = apply

  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.app.statement :
      st.resources == toset([var.kms_key_arn]) if anytrue([for a in st.actions : startswith(a, "kms:")])
    ])
    error_message = "앱 IAM 정책의 KMS 권한은 이 환경 키에만 걸려야 한다."
  }

  assert {
    condition = length([
      for st in data.aws_iam_policy_document.app.statement : st
      if st.actions == toset(["kms:Decrypt", "kms:GenerateDataKey"]) &&
      anytrue([for c in st.condition : c.variable == "kms:ViaService" && c.values == tolist(["s3.ap-northeast-2.amazonaws.com"])])
    ]) == 1
    error_message = "앱 IAM 정책은 S3를 거친 kms:Decrypt, kms:GenerateDataKey만 허용해야 한다."
  }

  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.app.statement :
      alltrue([for r in st.resources : endswith(r, "/backups/*")]) if contains(st.actions, "s3:PutObject")
    ])
    error_message = "앱 사용자는 backups/에만 쓸 수 있어야 한다."
  }

  assert {
    condition = anytrue([
      for st in data.aws_iam_policy_document.app.statement :
      st.actions == toset(["s3:GetObject"]) && st.resources == toset(["arn:aws:s3:::santacut-dev-backup-123456789012/config/*"])
    ])
    error_message = "앱 사용자는 config/를 읽기만 해야 한다."
  }
}

run "cloud_init_fetches_secrets_from_own_bucket" {
  command = plan

  assert {
    condition     = strcontains(aws_lightsail_instance.app.user_data, "santacut-dev-backup-123456789012/config/app.env")
    error_message = "첫 부팅 스크립트는 자기 환경 백업 버킷의 config/app.env를 받아야 한다."
  }

  assert {
    condition     = !strcontains(aws_lightsail_instance.app.user_data, " age ")
    error_message = "첫 부팅 스크립트에 age 설치가 남아 있으면 안 된다."
  }
}

run "kms_alias_instead_of_arn_is_rejected" {
  command = plan

  variables {
    kms_key_arn = "alias/santacut-dev"
  }

  expect_failures = [var.kms_key_arn]
}
