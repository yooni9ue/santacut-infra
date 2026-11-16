output "instance_name" {
  description = "Lightsail 인스턴스 이름."
  value       = aws_lightsail_instance.app.name
}

output "static_ip" {
  description = "앱 서버 고정 IP. 앱 레포 배포 워크플로의 접속 주소로 쓴다."
  value       = aws_lightsail_static_ip.app.ip_address
}

output "fqdn" {
  description = "이 환경의 접속 도메인. 도메인이 없으면 null이다."
  value       = one(aws_route53_record.app[*].fqdn)
}

output "app_url" {
  description = "접속 주소. 도메인이 있으면 https://<fqdn>, 없으면 http://<고정 IP>다."
  value       = var.fqdn == null ? "http://${aws_lightsail_static_ip.app.ip_address}" : "https://${var.fqdn}"
}

output "backup_bucket" {
  description = "SQLite 암호화 백업 버킷 이름(rclone 원격 경로에 쓴다)."
  value       = aws_s3_bucket.backup.bucket
}

output "app_iam_user" {
  description = "앱이 Bedrock과 백업 버킷에 접근할 때 쓰는 IAM 사용자. 액세스 키는 docs/operations.md 절차로 발급한다."
  value       = aws_iam_user.app.name
}
