output "state_bucket" {
  description = "envs/* 원격 상태 버킷. GitHub 레포 변수 TF_STATE_BUCKET에 넣는다."
  value       = aws_s3_bucket.state.bucket
}

output "zone_id" {
  description = "Route 53 호스팅 영역 ID. 도메인이 없으면 null이다."
  value       = one(aws_route53_zone.main[*].zone_id)
}

output "name_servers" {
  description = "가비아 도메인 관리에서 네임서버로 등록할 값. 도메인이 없으면 null이다."
  value       = one(aws_route53_zone.main[*].name_servers)
}

output "plan_role_arn" {
  description = "PR plan용 역할. GitHub 레포 변수 AWS_PLAN_ROLE_ARN에 넣는다."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arns" {
  description = "환경별 apply 역할. 각 GitHub Environment 변수 AWS_APPLY_ROLE_ARN에 넣는다."
  value       = { for env, role in aws_iam_role.apply : env => role.arn }
}
