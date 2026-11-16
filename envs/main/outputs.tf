output "static_ip" {
  description = "운영 앱 서버 고정 IP."
  value       = module.app.static_ip
}

output "fqdn" {
  description = "운영 접속 도메인. 도메인이 없으면 null이다."
  value       = module.app.fqdn
}

output "app_url" {
  description = "운영 접속 주소. 도메인이 없으면 http://<고정 IP>다."
  value       = module.app.app_url
}

output "instance_name" {
  description = "운영 Lightsail 인스턴스 이름."
  value       = module.app.instance_name
}

output "backup_bucket" {
  description = "운영 백업 버킷."
  value       = module.app.backup_bucket
}

output "app_iam_user" {
  description = "운영 앱 IAM 사용자."
  value       = module.app.app_iam_user
}

output "kms_key_arn" {
  description = "main KMS 키 ARN. backup.env의 sse_kms_key_id에 넣는다."
  value       = module.app.kms_key_arn
}
