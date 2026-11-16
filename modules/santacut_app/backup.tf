# 인스턴스 밖에 두는 SQLite 백업과 암호화된 앱 설정. 둘 다 환경별 KMS 키로 서버 쪽 암호화(SSE-KMS)한다.
# - backups/: 앱 레포 backup.sh가 rclone으로 올린다. 수명 주기 규칙으로 만료된다.
# - config/app.env: 운영자가 scripts/put-secrets.sh로 올리고, 인스턴스가 부팅 때 받는다. 만료되지 않는다.
resource "aws_s3_bucket" "backup" {
  bucket = "${local.name}-backup-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # 객체마다 KMS를 부르지 않고 버킷 키를 써서 KMS 요청 요금을 줄인다.
    bucket_key_enabled = true
  }
}

# 앱 키가 유출돼도 덮어쓰기로 백업을 잃지 않도록 이전 버전을 남긴다.
resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  # backups/만 만료한다. config/app.env는 이 규칙에 걸리지 않아 지워지지 않는다.
  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.backup_noncurrent_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.backup]
}

# TLS 전용 + SSE-KMS 강제.
data "aws_iam_policy_document" "backup_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # 올리는 쪽이 SSE-KMS를 명시하지 않으면 거부한다. 기본 암호화가 있어도 클라이언트 설정 실수를 바로 드러낸다.
  statement {
    sid       = "DenyPutWithoutKms"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # aws:kms만 주고 키를 빼면 AWS 관리형 키(aws/s3)로 암호화된다. 이 환경 키 ARN을 명시해야만 올릴 수 있다.
  statement {
    sid       = "DenyPutWithOtherKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.backup_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.backup]
}
