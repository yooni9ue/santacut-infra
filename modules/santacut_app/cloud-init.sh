#!/bin/bash
# Lightsail 첫 부팅 때 한 번 실행된다. 앱 레포 deploy.sh와 backup.sh가 기대하는 환경을 만든다.
# Terraform templatefile로 렌더링한다. 셸 변수는 $${...}로 써야 Terraform 보간과 겹치지 않는다.
# 인스턴스에는 ignore_changes = [user_data]가 걸려 있어, 이 파일을 고쳐도 이미 있는 인스턴스에는 반영되지 않는다.
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
apt_get install -y ca-certificates curl sqlite3 rclone unattended-upgrades

# Docker 공식 저장소에서 엔진과 Compose 플러그인을 설치한다.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
arch="$(dpkg --print-architecture)"
echo "deb [arch=$${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $${VERSION_CODENAME} stable" \
  >/etc/apt/sources.list.d/docker.list
apt_get update
apt_get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# 보안 업데이트를 자동으로 적용한다.
dpkg-reconfigure -f noninteractive unattended-upgrades

# 앱 디렉터리. 앱 IAM 사용자 자격 증명(aws/credentials)과 backup.env는 운영자가 직접 채운다(docs/operations.md 6절).
install -d -m 0750 -o ubuntu -g ubuntu /opt/santacut /opt/santacut/releases /opt/santacut/backups /opt/santacut/bin
install -d -m 0700 -o ubuntu -g ubuntu /opt/santacut/aws

# 앱 설정(.env) 파일은 디스크에 두지 않는다(컨테이너 메타데이터에는 남는다, docs/operations.md 6절). S3 config/app.env(SSE-KMS)를 부팅 때 받아 tmpfs(/run)에만 둔다.
# 복호화는 S3가 하고, 앱 IAM 사용자에게 S3 경유 kms:Decrypt만 있어 이 버킷 밖에서는 키를 쓸 수 없다.
cat >/opt/santacut/bin/fetch-secrets.sh <<'FETCH'
#!/bin/bash
# S3의 암호화된 앱 설정을 /run/santacut/app.env(tmpfs, 0600, ubuntu)로 받는다. 값은 출력하지 않는다.
# 앱(Spring)이 Bedrock을 부를 액세스 키는 S3에 두지 않고, 자격 증명 파일에서 읽어 받은 설정 뒤에 붙인다.
set -euo pipefail
umask 077
export AWS_SHARED_CREDENTIALS_FILE=/opt/santacut/aws/credentials
# server_side_encryption이 있어야 rclone이 KMS 객체의 ETag를 MD5로 오인하지 않는다. 값의 콜론 때문에 따옴표로 감싼다.
src=":s3,provider=AWS,env_auth=true,region=ap-northeast-2,no_check_bucket=true,server_side_encryption='aws:kms':${backup_bucket}/config/app.env"
dir=/run/santacut
dst="$dir/app.env"
[[ -r "$AWS_SHARED_CREDENTIALS_FILE" ]] || { echo "자격 증명 파일이 없다: $AWS_SHARED_CREDENTIALS_FILE" >&2; exit 1; }
[[ -d "$dir" ]] || install -d -m 0700 "$dir"
for i in 1 2 3 4 5; do
  if rclone copyto --quiet "$src" "$dst.tmp"; then
    {
      tr -d '\015' <"$dst.tmp"
      echo
      tr -d '\015' <"$AWS_SHARED_CREDENTIALS_FILE" | awk '
        match($0, /^aws_access_key_id[ \t]*=[ \t]*/)     { print "AWS_ACCESS_KEY_ID=" substr($0, RLENGTH + 1) }
        match($0, /^aws_secret_access_key[ \t]*=[ \t]*/) { print "AWS_SECRET_ACCESS_KEY=" substr($0, RLENGTH + 1) }
      '
    } >"$dst.new"
    rm -f "$dst.tmp"
    chmod 0600 "$dst.new"
    mv -f "$dst.new" "$dst"
    echo "fetch-secrets: OK"
    exit 0
  fi
  rm -f "$dst.tmp" "$dst.new"
  sleep $((i * 5))
done
echo "fetch-secrets: 앱 설정을 받지 못했다" >&2
exit 1
FETCH
chown ubuntu:ubuntu /opt/santacut/bin/fetch-secrets.sh
chmod 0750 /opt/santacut/bin/fetch-secrets.sh

# 부팅 때 Docker보다 먼저 앱 설정을 받는다. 자격 증명 파일이 생기기 전(첫 부팅)에는 건너뛴다.
# Compose는 env_file: /run/santacut/app.env 로 이 파일을 읽는다.
cat >/etc/systemd/system/santacut-secrets.service <<'UNIT'
[Unit]
Description=santacut: S3의 암호화된 앱 설정을 tmpfs로 받기
Wants=network-online.target
After=network-online.target
Before=docker.service
ConditionPathExists=/opt/santacut/aws/credentials

[Service]
Type=oneshot
RemainAfterExit=yes
User=ubuntu
Group=ubuntu
RuntimeDirectory=santacut
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
ExecStart=/opt/santacut/bin/fetch-secrets.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable santacut-secrets.service

# 20GB 디스크(nano_3_0)에 SQLite와 스왑이 같이 있으므로 배포 산출물을 주마다 정리한다.
# 롤백용으로 최근 7일 이미지와 최근 릴리스 3개는 남긴다.
cat >/etc/cron.weekly/santacut-cleanup <<'CLEANUP'
#!/bin/bash
set -euo pipefail
docker image prune -af --filter "until=168h" >/dev/null
current=$(readlink -f /opt/santacut/current 2>/dev/null || true)
ls -1dt /opt/santacut/releases/*/ 2>/dev/null | tail -n +4 | while read -r dir; do
  [[ "$${dir%/}" == "$current" ]] || rm -rf -- "$dir"
done
CLEANUP
chmod 0755 /etc/cron.weekly/santacut-cleanup

echo "santacut-init: OK"
SCRIPT
