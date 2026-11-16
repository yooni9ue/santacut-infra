#!/bin/bash
# Lightsail 첫 부팅 때 한 번 실행된다. 앱 레포 deploy.sh와 backup.sh가 기대하는 환경을 만든다.
# Lightsail이 앞에 자체 스크립트를 붙여 /bin/sh로 실행할 수 있으므로 본문을 bash에 넘긴다.
# 결과 확인: cloud-init status --wait, /var/log/santacut-init.log (docs/operations.md 5절)
bash -s <<'SCRIPT' >/var/log/santacut-init.log 2>&1
set -Eeuo pipefail

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

# 512MB 번들(nano_3_0)에서 Spring과 Caddy, apt가 메모리를 넘기지 않게 1GB 스왑을 먼저 둔다.
# 다시 실행해도 결과가 같다. 스왑은 비상용이라 swappiness를 낮게 둔다.
if [[ ! -f /swapfile ]]; then
  fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
fi
swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
echo 'vm.swappiness=10' >/etc/sysctl.d/99-santacut-swap.conf
sysctl -p /etc/sysctl.d/99-santacut-swap.conf

apt_get update
apt_get install -y ca-certificates curl sqlite3 age rclone unattended-upgrades

# Docker 공식 저장소에서 엔진과 Compose 플러그인을 설치한다.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
arch="$(dpkg --print-architecture)"
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  >/etc/apt/sources.list.d/docker.list
apt_get update
apt_get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# 보안 업데이트를 자동으로 적용한다.
dpkg-reconfigure -f noninteractive unattended-upgrades

# 앱 디렉터리. .env와 backup.env는 운영자가 직접 채운다(docs/operations.md).
install -d -m 0750 -o ubuntu -g ubuntu /opt/santacut /opt/santacut/releases /opt/santacut/backups

# 20GB 디스크(nano_3_0)에 SQLite와 스왑이 같이 있으므로 배포 산출물을 주마다 정리한다.
# 롤백용으로 최근 7일 이미지와 최근 릴리스 3개는 남긴다.
cat >/etc/cron.weekly/santacut-cleanup <<'CLEANUP'
#!/bin/bash
set -euo pipefail
docker image prune -af --filter "until=168h" >/dev/null
current=$(readlink -f /opt/santacut/current 2>/dev/null || true)
ls -1dt /opt/santacut/releases/*/ 2>/dev/null | tail -n +4 | while read -r dir; do
  [[ "${dir%/}" == "$current" ]] || rm -rf -- "$dir"
done
CLEANUP
chmod 0755 /etc/cron.weekly/santacut-cleanup

echo "santacut-init: OK"
SCRIPT
