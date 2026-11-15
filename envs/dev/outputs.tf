output "static_ip" {
  description = "dev 앱 서버 고정 IP."
  value       = module.app.static_ip
}

output "fqdn" {
  description = "dev 접속 도메인."
  value       = module.app.fqdn
}

output "instance_name" {
  description = "dev Lightsail 인스턴스 이름."
  value       = module.app.instance_name
}

output "backup_bucket" {
  description = "dev 백업 버킷."
  value       = module.app.backup_bucket
}

output "app_iam_user" {
  description = "dev 앱 IAM 사용자."
  value       = module.app.app_iam_user
}
