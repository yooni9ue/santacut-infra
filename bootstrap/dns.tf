# 가비아 도메인의 네임서버를 이 호스팅 영역의 name_servers로 바꿔 위임한다(docs/operations.md).
# 두 환경이 같이 쓰므로 bootstrap에 둔다. 환경별 A 레코드는 envs/*에서 만든다.
resource "aws_route53_zone" "main" {
  name = var.domain_name

  lifecycle {
    prevent_destroy = true
  }
}
