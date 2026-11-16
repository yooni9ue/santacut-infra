#!/usr/bin/env bash
# 운영자 PC에서 앱 설정(.env)을 환경별 KMS 키로 암호화해 s3://<백업 버킷>/config/app.env에 올린다.
# 사용법: scripts/put-secrets.sh <dev|main> <로컬 .env 경로>
# - AWS_PROFILE(기본 santacut)의 관리자 자격 증명을 쓴다.
# - 다른 사용자가 읽을 수 있는 파일(예: 644)은 거부한다. chmod 600 후 다시 실행한다.
#   Git Bash(NTFS)는 권한을 표현하지 못해 항상 거부되므로 WSL, Linux, macOS에서 실행한다.
# - 파일 내용은 화면에 출력하지 않는다. 이 스크립트에서 set -x를 켜지 않는다.
set -euo pipefail

usage() {
  echo "사용법: $0 <dev|main> <로컬 .env 경로>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
env="$1"
src="$2"

case "$env" in
  dev | main) ;;
  *) usage ;;
esac

export AWS_PROFILE="${AWS_PROFILE:-santacut}"
region=ap-northeast-2

[[ -f "$src" && -r "$src" ]] || {
  echo "파일을 읽을 수 없다: $src" >&2
  exit 1
}
[[ -s "$src" ]] || {
  echo "빈 파일이다: $src" >&2
  exit 1
}

# 권한 마지막 자리(기타 사용자)가 0이 아니면 거부한다. GNU stat과 BSD stat을 모두 지원한다.
mode=$(stat -c '%a' "$src" 2>/dev/null || stat -f '%Lp' "$src")
if [[ "${mode: -1}" != "0" ]]; then
  echo "다른 사용자가 읽을 수 있는 파일이다(권한 $mode). chmod 600 \"$src\" 후 다시 실행한다." >&2
  exit 1
fi

account=$(aws sts get-caller-identity --query Account --output text)
bucket="santacut-${env}-backup-${account}"

# 버킷 정책이 이 환경 키 ARN을 요구하므로 별칭을 키 ARN으로 바꿔 넘긴다.
key_arn=$(aws kms describe-key --region "$region" --key-id "alias/santacut-${env}" --query KeyMetadata.Arn --output text)

aws s3 cp "$src" "s3://${bucket}/config/app.env" \
  --region "$region" \
  --sse aws:kms \
  --sse-kms-key-id "$key_arn" \
  --only-show-errors

# 값이 아니라 암호화 메타데이터만 확인해 출력한다.
aws s3api head-object --region "$region" --bucket "$bucket" --key config/app.env \
  --query '{ServerSideEncryption: ServerSideEncryption, SSEKMSKeyId: SSEKMSKeyId, BucketKeyEnabled: BucketKeyEnabled, LastModified: LastModified}' \
  --output table

echo "올렸다: s3://${bucket}/config/app.env. 인스턴스에서 sudo systemctl restart santacut-secrets 후 앱을 다시 띄운다."
