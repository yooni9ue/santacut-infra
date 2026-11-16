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

# 프론트엔드(Vercel)는 루트와 www를 쓴다. 서버는 api·api-dev 하위 도메인이다(envs/*).
# Vercel 프로젝트의 Settings → Domains에 santacut.me와 www.santacut.me를 먼저 추가해야 인증서가 발급된다.
# 값은 Vercel 안내의 기본값이다. Vercel이 프로젝트 전용 값을 보여 주면 변수로 바꾼다.
variable "frontend_apex_ipv4" {
  description = "루트 도메인 A 레코드(Vercel). 비우면 레코드를 만들지 않는다."
  type        = string
  default     = "76.76.21.21"
}

variable "frontend_www_target" {
  description = "www CNAME 대상(Vercel). 비우면 레코드를 만들지 않는다."
  type        = string
  default     = "cname.vercel-dns.com"
}

resource "aws_route53_record" "frontend_apex" {
  count = local.domain == null || var.frontend_apex_ipv4 == "" ? 0 : 1

  zone_id = aws_route53_zone.main[0].zone_id
  name    = local.domain
  type    = "A"
  ttl     = 300
  records = [var.frontend_apex_ipv4]
}

resource "aws_route53_record" "frontend_www" {
  count = local.domain == null || var.frontend_www_target == "" ? 0 : 1

  zone_id = aws_route53_zone.main[0].zone_id
  name    = "www.${local.domain}"
  type    = "CNAME"
  ttl     = 300
  records = [var.frontend_www_target]
}

# 프론트 개발 환경(Vercel). Vercel 프로젝트 Domains에 dev.santacut.me를 추가하고 develop 브랜치에 연결한다.
variable "frontend_dev_target" {
  description = "dev 프론트 CNAME 대상(Vercel). 비우면 레코드를 만들지 않는다."
  type        = string
  default     = "cname.vercel-dns.com"
}

resource "aws_route53_record" "frontend_dev" {
  count = local.domain == null || var.frontend_dev_target == "" ? 0 : 1

  zone_id = aws_route53_zone.main[0].zone_id
  name    = "dev.${local.domain}"
  type    = "CNAME"
  ttl     = 300
  records = [var.frontend_dev_target]
}
