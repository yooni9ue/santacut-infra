data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "santacut-${var.environment}"
}

# 앱 서버. 앱 레포의 Compose 스택(Caddy + Spring)이 이 인스턴스에서 돈다.
resource "aws_lightsail_key_pair" "deploy" {
  name       = "${local.name}-deploy"
  public_key = var.ssh_public_key
}

resource "aws_lightsail_instance" "app" {
  name              = "${local.name}-app"
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.deploy.name
  user_data         = file("${path.module}/cloud-init.sh")

  # IPv6 방화벽은 IPv4와 따로 관리되고 기본값이 전체 허용이다. AAAA 레코드가 없으니 IPv4만 쓴다.
  ip_address_type = "ipv4"

  # SQLite 파일이 이 디스크에 있으므로 매일 디스크 전체 스냅숏을 남긴다.
  add_on {
    type          = "AutoSnapshot"
    snapshot_time = var.snapshot_time_utc
    status        = "Enabled"
  }

  lifecycle {
    # user_data를 고치면 인스턴스가 다시 만들어져 SQLite 데이터가 사라진다.
    # 초기 설정 변경은 인스턴스에 직접 적용하고, 재생성은 의도할 때만 한다.
    ignore_changes  = [user_data]
    prevent_destroy = true
  }
}

resource "aws_lightsail_static_ip" "app" {
  name = "${local.name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "app" {
  static_ip_name = aws_lightsail_static_ip.app.name
  instance_name  = aws_lightsail_instance.app.name
}

# 이 리소스가 인스턴스의 공개 포트 전체를 관리한다. 여기에 없는 포트는 닫힌다.
# port_info를 바꾸면 리소스가 교체되면서 80/443이 몇 초 닫힌다(docs/operations.md 7절).
resource "aws_lightsail_instance_public_ports" "app" {
  instance_name = aws_lightsail_instance.app.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = var.ssh_allowed_cidrs
  }

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidrs     = ["0.0.0.0/0"]
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
    cidrs     = ["0.0.0.0/0"]
  }
}

resource "aws_route53_record" "app" {
  zone_id = var.zone_id
  name    = var.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.app.ip_address]
}
