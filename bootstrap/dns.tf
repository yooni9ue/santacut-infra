locals {
  # 도메인을 사기 전에는 비워 둔다. CI는 레포 변수 DOMAIN_NAME이 없으면 빈 문자열을 넘기므로 null과 같이 본다.
  domain = var.domain_name == null ? null : (trimspace(var.domain_name) == "" ? null : lower(trimspace(var.domain_name)))
}

# 가비아 도메인의 네임서버를 이 호스팅 영역의 name_servers로 바꿔 위임한다(docs/operations.md 2단계).
# 두 환경이 같이 쓰므로 bootstrap에 둔다. 환경별 A 레코드는 envs/*에서 만든다.
# 도메인이 없으면 만들지 않는다(월 0.5달러 절약). domain_name을 넣고 다시 적용하면 생긴다.
resource "aws_route53_zone" "main" {
  count = local.domain == null ? 0 : 1

  name = local.domain

  lifecycle {
    prevent_destroy = true
  }
}
