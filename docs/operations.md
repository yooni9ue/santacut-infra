# 운영 절차

처음 설정은 1~7단계를 순서대로 한 번 한다. 8단계부터는 필요할 때 찾아 쓴다.

## 1. bootstrap (처음 한 번)

준비물: 관리자 권한 AWS 자격 증명(로컬), Terraform 1.17.

```sh
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # 도메인, 예산, 알림 이메일을 채운다
terraform init
terraform apply
```

상태 버킷은 이 스택이 만들기 때문에 첫 적용은 로컬 상태로 한다. 적용이 끝나면 바로 상태를 그 버킷으로 옮긴다.

1. `bootstrap/backend.tf`를 아래 내용으로 만든다.

   ```hcl
   terraform {
     backend "s3" {
       key          = "bootstrap/terraform.tfstate"
       region       = "ap-northeast-2"
       encrypt      = true
       use_lockfile = true
     }
   }
   ```

2. `terraform init -migrate-state -backend-config="bucket=<state_bucket 출력값>"`을 실행한다.
3. 로컬 `terraform.tfstate*`를 지우고 `backend.tf`를 커밋한다.

apply 역할은 `envs/<env>/*` 키에만 쓸 수 있어서 CI가 bootstrap 상태를 바꾸지 못한다. 이후 권한, 예산, OIDC 설정을 바꿀 때는 관리자가 로컬에서 `terraform init -backend-config="bucket=..."` 후 다시 적용한다.

출력값은 다음 단계에서 쓴다: `state_bucket`, `name_servers`, `plan_role_arn`, `apply_role_arns`, `app_deploy_role_arns`.

## 2. 가비아 네임서버 위임

가비아 도메인 관리 → 네임서버 설정에서 `name_servers` 출력값 4개를 등록한다. 반영까지 최대 하루가 걸릴 수 있다. `dig NS <도메인>`으로 확인한다.

## 3. Bedrock 모델 활성화

상용 리전에는 모델 접근 신청 절차가 없다. 계정에서 처음 호출할 때 AWS Marketplace 구독이 자동으로 시작되며, 그 호출 주체에는 `aws-marketplace:Subscribe` 권한이 필요하다. 앱 IAM 사용자에게는 이 권한을 주지 않으므로 관리자가 먼저 한 번 호출한다.

1. 서울 리전 Bedrock 콘솔의 모델 카탈로그에서 Claude Haiku 5.5를 찾아 **기반 모델 ID**(`anthropic.`으로 시작)를 확인한다. Global 추론 프로파일 ID는 앞에 `global.`을 붙인 값이다.
2. Global 프로파일이 서울 리전에 있는지 확인한다.

   ```sh
   aws bedrock list-inference-profiles --region ap-northeast-2 \
     --query "inferenceProfileSummaries[?starts_with(inferenceProfileId,'global.anthropic')].inferenceProfileId"
   ```

3. 관리자 자격 증명으로 플레이그라운드나 CLI에서 Global 프로파일을 한 번 호출한다.
4. 활성화를 확인한다.

   ```sh
   aws bedrock get-foundation-model-availability --region ap-northeast-2 --model-id <기반 모델 ID>
   # agreementAvailability.status 가 AVAILABLE 이어야 한다
   ```

5. Anthropic 사용 사례 제출(FTU)을 요구하면 콘솔 안내대로 제출한다.

### 개인정보 국외 이전 고지

Global 추론은 요청을 다른 나라 리전에서 처리할 수 있다. 개인정보 처리방침에 아래 항목을 모두 적는다(개인정보 보호법 제28조의8). 법률 검토는 별도로 받는다.

- 이전받는 자: Amazon Web Services, Inc.(연락처 포함)
- 이전 국가: AWS Global 추론 대상 리전 전체(특정 국가로 한정되지 않음을 명시)
- 이전 항목: 분석을 위해 보내는 대화 텍스트. 닉네임·세션 같은 식별 정보는 보내지 않는다
- 이전 시기와 방법: 분석 요청 시 암호화된 네트워크로 전송
- 이전 목적과 보유·이용 기간: AI 점수 산정, 처리 후 보관하지 않음(Bedrock 데이터 정책 확인)
- 거부 방법과 거부 시 효과: 분석 기능을 이용하지 않으면 이전되지 않는다

## 4. GitHub 레포 설정 (santacut-infra)

### OIDC sub 형식 확인

2026-07-15 이후 만든 레포는 OIDC 토큰의 `sub`가 `repo:OWNER@OWNER_ID/REPO@REPO_ID:...` 형식이다. 두 레포 모두 그 이후에 만들어져서, bootstrap 변수 `infra_oidc_subject_repo`, `app_oidc_subject_repo` 기본값을 이 형식으로 넣어 두었다(조직 `yooni9ue` ID 356647612, `santacut-infra` 1458963706, `santacut` 1457838283).

1. 레포를 다시 만들었다면 `gh api repos/yooni9ue/santacut-infra --jq '.id, .owner.id'`로 ID를 확인한다.
2. ID가 바뀌었으면 `bootstrap/terraform.tfvars`에 아래처럼 넣고 bootstrap을 다시 적용한다. 앱 레포도 같은 방법으로 넣는다.

   ```hcl
   infra_oidc_subject_repo = "repo:yooni9ue@<OWNER_ID>/santacut-infra@<REPO_ID>"
   ```

3. 첫 워크플로가 역할을 맡지 못하면 Actions 로그의 `Not authorized to perform sts:AssumeRoleWithWebIdentity`를 확인하고 `sub`를 맞춘다.

### 레포 변수 (Settings → Secrets and variables → Actions → Variables)

| 변수 | 값 |
| --- | --- |
| `TF_STATE_BUCKET` | bootstrap `state_bucket` |
| `AWS_PLAN_ROLE_ARN` | bootstrap `plan_role_arn` |
| `DOMAIN_NAME` | 서비스 도메인 |
| `SSH_PUBLIC_KEY` | 배포용 SSH 공개 키 |
| `SSH_ALLOWED_CIDRS` | HCL 목록 형식, /24 이상, 예: `["203.0.113.10/32"]` |
| `BEDROCK_MODEL_ID` | 3단계의 기반 모델 ID(`anthropic.`으로 시작) |
| `DEV_ENABLED` | 평소에는 비워 둔다. dev를 내렸을 때만 `false` |
| `HEALTH_PATH` | 상태 확인 경로. 비우면 `/v3/api-docs` |

### Environment 두 개 (Settings → Environments)

두 Environment 모두 **배포 브랜치를 `main`으로 제한**한다. 제한이 없으면 아무 브랜치에서나 apply 역할을 맡을 수 있다.

- `dev`: 변수 `AWS_APPLY_ROLE_ARN` = `apply_role_arns.dev`
- `main`: 변수 `AWS_APPLY_ROLE_ARN` = `apply_role_arns.main`, **Required reviewers**에 운영 승인자를 넣는다.

승인자는 같은 실행의 `plan-main` 잡 실행 요약에 있는 plan을 보고 승인한다. 승인하면 그 plan이 그대로 적용된다. 승인 대기가 오래된 실행은 거절하고, 새 실행으로 진행한다.

### 레포 공개 범위

이 레포는 **공개 레포**(또는 GitHub Enterprise)여야 한다. Free·Pro·Team 플랜의 비공개 레포에서는 Environment의 Required reviewers가 동작하지 않아 운영 적용이 승인 없이 진행되고, Actions 사용량도 무료 포함분을 넘을 수 있다. Environment 설정 후 승인자가 실제로 걸렸는지 확인한다.

```sh
gh api repos/yooni9ue/santacut-infra/environments/main --jq .protection_rules
```

비공개로 써야 하면 승인을 사람이 로컬 apply로 대신하고, 상태 확인은 인스턴스 cron으로 옮긴다.

### IAM으로 막지 못하는 위험

dev와 main이 같은 계정이라 환경 분리는 이름 접두사와 `Environment` 태그 조건으로 한다. 아래는 AWS가 리소스 단위 조건을 지원하지 않아 dev apply 역할에도 열려 있다. dev Environment의 브랜치 제한(위)과 PR 리뷰가 이 위험을 막는다.

- Lightsail 고정 IP: 태그를 지원하지 않아 `Attach/Detach/ReleaseStaticIp`를 환경별로 막을 수 없다.
- Lightsail 애드온: `EnableAddOn/DisableAddOn`은 태그 조건이 평가되지 않아 운영 자동 스냅숏을 끌 수 있다. 8단계의 애드온 확인으로 알아차린다.
- Lightsail 키 페어 가져오기: `ImportKeyPair` 요청에는 태그가 없어 생성 시점에 환경을 강제할 수 없다. 이어지는 태그 달기는 자기 환경 값으로만 허용된다.

## 5. 환경 적용과 첫 부팅 확인

PR을 병합하면 CI가 dev를 적용하고, 운영 plan을 만든 뒤 승인을 받아 main을 적용한다. 로컬에서 직접 적용할 때:

```sh
cd envs/dev
cp terraform.tfvars.example terraform.tfvars   # 값 채우기(커밋 금지)
terraform init -backend-config="bucket=<state_bucket>"
terraform plan
terraform apply
```

첫 적용에서 `AccessDenied`가 나면 그 액션을 `bootstrap/github_oidc.tf`의 `lightsail_apply_actions`에 더하고 bootstrap을 다시 적용한다.

적용 후 인스턴스에 접속해 첫 부팅 스크립트가 끝났는지 확인한다. Terraform은 스크립트가 실패해도 성공으로 끝난다.

```sh
cloud-init status --wait                 # status: done
tail -n 5 /var/log/santacut-init.log     # 마지막 줄: santacut-init: OK
docker compose version
ls -ld /opt/santacut/releases /opt/santacut/backups
```

방화벽도 확인한다. IPv6 규칙이 없어야 한다.

```sh
aws lightsail get-instance-port-states --instance-name santacut-dev-app
```

## 6. 인스턴스 비밀값 설정

### 앱 IAM 사용자 액세스 키

액세스 키는 Terraform 상태에 남지 않도록 사람이 발급한다.

```sh
aws iam create-access-key --user-name santacut-dev-app
```

발급한 키로 Bedrock 호출 권한을 확인한다. 프로파일 ID로는 성공하고 기반 모델 ID로는 거부되어야 한다.

```sh
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
aws bedrock-runtime converse --region ap-northeast-2 --model-id global.<기반 모델 ID> \
  --messages '[{"role":"user","content":[{"text":"ping"}]}]'          # 성공
aws bedrock-runtime converse --region ap-northeast-2 --model-id <기반 모델 ID> \
  --messages '[{"role":"user","content":[{"text":"ping"}]}]'          # AccessDeniedException
```

### `/opt/santacut/.env` (권한 600, 소유자 ubuntu)

앱 레포 `backend/ci-cd/deploy/.env.example`의 필수 키(`DOMAIN`, `ACME_EMAIL`, `APP_SEASON_YEAR` 등)를 채우고, Bedrock 설정을 더한다. 변수 이름은 앱 레포 설정과 맞춘다.

```sh
DOMAIN=dev.santacut.kr
ACME_EMAIL=operator@example.com
AWS_REGION=ap-northeast-2
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
# 반드시 global.로 시작하는 프로파일 ID. 기반 모델 ID로 호출하면 IAM 조건에 걸려 거부된다.
# 비스트리밍 호출(bedrock-runtime Converse, InvokeModel)만 허용된다.
BEDROCK_MODEL_ID=global.anthropic.claude-haiku-5-5-...
```

### `/opt/santacut/backup.env` (권한 600, 소유자 ubuntu)

`backup.sh`는 이 파일을 `source`하고 rclone을 직접 실행한다. 자식 프로세스인 rclone이 키를 받도록 `export`를 붙인다. 앱 사용자에게는 버킷 생성 권한이 없으므로 `no_check_bucket=true`가 필요하다.

```sh
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
BACKUP_AGE_RECIPIENT=age1...
BACKUP_REMOTE=:s3,provider=AWS,env_auth=true,region=ap-northeast-2,no_check_bucket=true:<backup_bucket>/sqlite
```

### age 개인키

S3 백업은 age 공개키로 암호화된다. **개인키는 인스턴스에 두지 않고** bootstrap 관리자 자격 증명과 같은 수준으로 비밀번호 관리자에 보관한다. 개인키를 잃으면 S3 백업 전체를 복원할 수 없다.

### 키 교체

90일마다 새 키를 발급해 `.env`와 `backup.env` 두 곳을 바꾸고, 앱을 다시 띄운 뒤 예전 키를 `aws iam delete-access-key`로 지운다.

## 7. 앱 배포 연동 (앱 레포에서 할 일)

- 앱 레포 GitHub Environment 이름을 `dev`, `main`으로 맞추고, 각각 배포 브랜치를 `main`으로 제한한다. 변수 `AWS_DEPLOY_ROLE_ARN`에 `app_deploy_role_arns.<env>`를 넣는다.
- 앱의 Compose에서 Ollama 설정을 빼고 Bedrock 설정과 AWS 키를 넘긴다. 앱은 bedrock-runtime Converse(비스트리밍)로 호출하고, 요청마다 최대 출력 토큰을 정하고, 호출 전에 일일 토큰 한도를 확인한다.
- 릴리스 묶음(tar)에 `scripts/deploy.sh`와 함께 **`scripts/backup.sh`를 넣는다.** 지금 앱 레포 워크플로는 `deploy.sh`만 넣는다.
- 배포 대상 주소는 각 환경 출력값 `static_ip`다.

### 배포 중 임시 SSH

SSH(22)는 평소 `SSH_ALLOWED_CIDRS`에만 열려 있다. 배포 워크플로는 배포 역할로 러너 IP에 22번을 열고, 배포가 끝나면 실패해도(`if: always()`) 닫는다.

```sh
ip=$(curl -fsS https://checkip.amazonaws.com)
aws lightsail open-instance-public-ports --instance-name santacut-main-app \
  --port-info fromPort=22,toPort=22,protocol=TCP,cidrs=${ip}/32
# ... 배포 ...
aws lightsail close-instance-public-ports --instance-name santacut-main-app \
  --port-info fromPort=22,toPort=22,protocol=TCP,cidrs=${ip}/32
```

미확인: 같은 22번에 CIDR만 다른 요청이 기존 운영자 CIDR과 합쳐지는지, 닫기가 러너 CIDR만 빼는지 22번 전체를 닫는지 API 문서에 적혀 있지 않다. **dev 첫 배포에서 연 직후와 닫은 직후 두 번** `get-instance-port-states`를 확인한다. 22번에 운영자 CIDR이 남아 있어야 한다. 다르게 동작하면 배포 역할에 `PutInstancePublicPorts`를 더하고, 워크플로가 운영자 CIDR을 포함한 전체 규칙을 다시 넣는 방식으로 바꾼다.

공개 포트 규칙(`aws_lightsail_instance_public_ports`)을 바꾸는 apply는 리소스를 교체하면서 80/443을 몇 초 닫는다. 운영자 CIDR 변경은 트래픽이 적은 시간에 하고, 앱 배포 중에는 인프라 apply를 돌리지 않는다.

### 백업 스크립트 설치와 cron

`deploy.sh`는 `/opt/santacut/backup.sh`가 없으면 두 번째 배포부터 멈춘다. 첫 배포 뒤 설치한다.

```sh
sudo install -o ubuntu -g ubuntu -m 0750 /opt/santacut/current/scripts/backup.sh /opt/santacut/backup.sh
( crontab -u ubuntu -l 2>/dev/null; echo '0 * * * * /opt/santacut/backup.sh >> /opt/santacut/backups/backup.log 2>&1' ) | crontab -u ubuntu -
```

릴리스 묶음에 아직 `backup.sh`가 없다면 앱 레포 체크아웃에서 `scp backend/ci-cd/scripts/backup.sh ubuntu@<static_ip>:/tmp/`로 올린 뒤 같은 `install` 명령을 쓴다.

## 8. 관측과 알람

### 자동 확인 (GitHub Actions)

`.github/workflows/health.yml`이 매시간 두 환경의 HTTP 응답과 S3 백업 신선도(마지막 백업 3시간 이내)를 확인한다. 인스턴스 상태 알람은 컨테이너가 죽어도 울리지 않기 때문에 이 확인이 필요하다.

- 실패 메일은 이 워크플로의 cron을 마지막으로 고친 사용자에게만 간다. 그 사용자의 GitHub 알림 설정에서 Actions 실패 메일이 켜져 있는지 확인한다.
- 공개 레포는 60일 동안 활동이 없으면 스케줄 워크플로가 자동으로 꺼진다. 주간 점검에서 `gh workflow view health`로 켜져 있는지 보고, 꺼졌으면 `gh workflow enable health`로 켠다.

### Lightsail 알람

`aws_lightsail_*`에는 알람 리소스가 없어 CLI로 한 번 건다(알람 요금은 적용 전에 요금 페이지에서 확인한다). 연락처 등록 후 받은 **인증 메일의 링크를 눌러야** 알람이 발송된다.

```sh
aws lightsail create-contact-method --protocol Email --contact-endpoint operator@example.com
for env in dev main; do
  aws lightsail put-alarm --alarm-name santacut-$env-status --monitored-resource-name santacut-$env-app \
    --metric-name StatusCheckFailed --comparison-operator GreaterThanOrEqualToThreshold \
    --threshold 1 --evaluation-periods 2 --contact-protocols Email --notification-enabled
  aws lightsail put-alarm --alarm-name santacut-$env-burst --monitored-resource-name santacut-$env-app \
    --metric-name BurstCapacityPercentage --comparison-operator LessThanOrEqualToThreshold \
    --threshold 20 --evaluation-periods 3 --contact-protocols Email --notification-enabled
done
```

### 주간 점검

- 상태 확인 워크플로가 켜져 있는지: `gh workflow view health`(최근 실행 시각 확인).
- 디스크: `df -h /`. 80%를 넘으면 오래된 이미지와 릴리스를 지운다. 배포 산출물은 첫 부팅 스크립트가 넣은 주간 정리 작업(`/etc/cron.weekly/santacut-cleanup`)이 지운다.
- 자동 스냅숏이 켜져 있는지: `aws lightsail get-instance --instance-name santacut-main-app --query 'instance.addOns'`의 `status`가 `Enabled`.
- 백업 목록: `set -a; . /opt/santacut/backup.env; set +a; rclone lsl "$BACKUP_REMOTE" | tail -3`.

## 9. 백업과 복구

- **자동 스냅숏**: 매일 UTC 18:00(한국 새벽 3시)에 인스턴스 디스크 전체를 남긴다. Lightsail은 최근 7개를 보관한다. **원본 인스턴스를 지우면 자동 스냅숏도 함께 지워진다.**
- **S3 백업**: `backup.sh`가 SQLite를 `.backup`으로 떠서 age로 암호화해 올린다. 객체는 30일 뒤 이전 버전이 되고, 그로부터 7일 뒤 영구 삭제된다(최대 37일 보관).

### S3 백업에서 SQLite 복원

출시 전에 dev에서 한 번 리허설한다.

1. 복원할 백업을 내려받는다(인스턴스에서).

   ```sh
   set -a; . /opt/santacut/backup.env; set +a
   rclone lsl "$BACKUP_REMOTE" | tail -5
   rclone copyto "$BACKUP_REMOTE/santacut-<시각>.sqlite.age" /tmp/restore.sqlite.age
   ```

2. 복호화는 **인스턴스 밖**(age 개인키가 있는 PC)에서 한다: `age -d -i <개인키 파일> -o restore.sqlite restore.sqlite.age`
3. 무결성을 확인한다: `sqlite3 restore.sqlite 'PRAGMA integrity_check;'` 결과가 `ok`.
4. 인스턴스로 올리고 앱을 멈춘 뒤 볼륨의 DB를 바꾼다.

   ```sh
   cd /opt/santacut/current
   docker compose --env-file /opt/santacut/.env -f deploy/compose.yml stop app
   vol=$(docker volume inspect santacut_santacut_data --format '{{ .Mountpoint }}')
   sudo cp "$vol/santacut.db" "/opt/santacut/backups/before-restore-$(date -u +%Y%m%dT%H%M%SZ).db"
   sudo install -o 10001 -g 10001 -m 0600 /tmp/restore.sqlite "$vol/santacut.db"   # 앱 컨테이너 사용자(UID 10001)
   sudo rm -f "$vol/santacut.db-wal" "$vol/santacut.db-shm"
   docker compose --env-file /opt/santacut/.env -f deploy/compose.yml start app
   ```

5. 쓰기가 되는지 확인한다: 참가자 등록이나 분석 제출 같은 쓰기 요청 하나가 성공해야 한다.

인스턴스를 통째로 잃었으면(자동 스냅숏도 없음) 새 인스턴스를 `terraform apply`로 만들고 5~7단계를 다시 한 뒤 위 복원을 한다.

### 인스턴스 교체 (사양 올리기, 장애 복구)

인스턴스 이름과 번들은 바꾸면 재생성되는 속성이고 `prevent_destroy`가 걸려 있어, Terraform만으로는 교체할 수 없다. 아래 순서를 지킨다. 먼저 dev에서 리허설한다.

1. 스냅숏을 준비한다.
   - **사양 올리기(인스턴스 정상)**: Caddy를 멈춰 요청을 끊고, 앱이 살아 있는 동안 마지막 백업을 올린 뒤(`backup.sh`는 실행 중인 앱 컨테이너 안에서 백업을 뜬다) 앱을 멈추고 지금 시점 수동 스냅숏을 뜬다.

     ```sh
     compose="docker compose --env-file /opt/santacut/.env -f /opt/santacut/current/deploy/compose.yml"
     $compose stop caddy
     /opt/santacut/backup.sh
     $compose stop app
     aws lightsail create-instance-snapshot --instance-name santacut-main-app \
       --instance-snapshot-name santacut-main-manual-$(date -u +%Y%m%d%H%M)
     ```

   - **장애 복구(인스턴스 사용 불가)**: 원본을 지우면 자동 스냅숏도 사라지므로 먼저 수동 스냅숏으로 복사한다.

     ```sh
     aws lightsail copy-snapshot --source-resource-name santacut-main-app --use-latest-restorable-auto-snapshot \
       --target-snapshot-name santacut-main-manual-$(date -u +%Y%m%d%H%M) --source-region ap-northeast-2
     ```

2. 스냅숏 생성·복사는 비동기다. `available`이 될 때까지 기다린다. **이 확인 전에는 원본을 지우지 않는다.**

   ```sh
   aws lightsail get-instance-snapshot --instance-snapshot-name santacut-main-manual-YYYYMMDDHHMM \
     --query instanceSnapshot.state
   ```

3. `terraform state rm module.app.aws_lightsail_instance.app module.app.aws_lightsail_static_ip_attachment.app module.app.aws_lightsail_instance_public_ports.app`
4. 옛 인스턴스를 지운다: `aws lightsail delete-instance --instance-name santacut-main-app`. 고정 IP는 남는다. 애드온 때문에 거부되면 `--force-delete-add-ons`를 붙인다(dev 리허설에서 확인).
5. 수동 스냅숏에서 **같은 이름**으로 새 인스턴스를 만든다. 사양을 올릴 때는 여기서 큰 번들을 고른다.

   ```sh
   aws lightsail create-instances-from-snapshot --instance-names santacut-main-app \
     --instance-snapshot-name santacut-main-manual-YYYYMMDDHHMM --availability-zone ap-northeast-2a \
     --bundle-id small_3_0 --key-pair-name santacut-main-deploy --ip-address-type ipv4 \
     --tags key=Environment,value=main key=Project,value=santacut key=ManagedBy,value=terraform
   ```

6. `terraform import module.app.aws_lightsail_instance.app santacut-main-app`
7. 번들을 바꿨다면 `envs/<env>/variables.tf`의 `bundle_id` **기본값을 PR로 바꿔 병합**한다. CI는 이 기본값을 쓰므로 로컬 `terraform.tfvars`만 바꾸면 다음 병합의 plan이 재생성을 계획하다 `prevent_destroy`에 걸린다. 월 고정비가 바뀌므로 README 비용 표와 bootstrap `monthly_budget_usd`도 함께 고친다.
8. `terraform apply`(또는 병합 후 CI)로 고정 IP 연결, 방화벽, 자동 스냅숏을 다시 맞추고, 실행 요약의 plan이 인스턴스 교체를 계획하지 않는지 확인한다. 새 인스턴스의 기본 방화벽은 22/80 전체 개방이므로 이 단계를 빼먹지 않는다.
9. 앱을 다시 띄운다. 스냅숏은 앱을 수동으로 멈춘 상태에서 떴기 때문에 `restart: unless-stopped` 정책으로는 자동으로 올라오지 않는다.

   ```sh
   docker compose --env-file /opt/santacut/.env -f /opt/santacut/current/deploy/compose.yml start app caddy
   curl -fsS https://<도메인>/v3/api-docs -o /dev/null && echo OK
   ```

10. 8절의 Lightsail 알람이 남아 있는지 `aws lightsail get-alarms`로 확인하고, 없으면 다시 건다.
11. 장애 복구였다면 스냅숏 시점의 SQLite는 최대 하루 전이다. 더 최신인 S3 백업으로 덮어쓸지 판단하고, 덮어쓰면 위 복원 절차를 따른다.

## 10. Bedrock 예산 차단과 해제

1. 첫 Bedrock 호출 다음 날, Cost Explorer에서 Bedrock 비용이 잡히는 서비스 이름을 확인한다. Anthropic 모델은 Marketplace 상품명으로 잡힐 수 있다.

   ```sh
   aws ce get-cost-and-usage --time-period Start=<어제>,End=<오늘> --granularity DAILY \
     --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
   ```

2. 그 이름으로 bootstrap 변수 `bedrock_cost_service_names`를 맞추고 다시 적용한다. 다음 날 `aws budgets describe-budget --account-id <계정> --budget-name santacut-bedrock --query Budget.CalculatedSpend.ActualSpend`가 0이 아닌지 확인한다.
3. 2단계 확인이 끝난 뒤에만 `enable_bedrock_stop = true`로 다시 적용한다. 실제 비용이 100%를 넘으면 `bedrock_stop_environments`의 앱 사용자에게 `santacut-deny-bedrock` 정책이 자동으로 붙는다. 청구 데이터가 하루 늦게 반영되므로 1차 방어는 앱의 일일 토큰 한도다.
4. 해제: 원인을 확인하고 예산을 올리거나 다음 달을 기다린 뒤 정책을 뗀다.

   ```sh
   for env in dev main; do
     aws iam detach-user-policy --user-name santacut-$env-app --policy-arn arn:aws:iam::<계정>:policy/santacut-deny-bedrock
   done
   ```

## 11. dev 내리기

dev가 당분간 필요 없으면 아래 순서로 내린다. dev 데이터는 사라지므로 필요한 백업을 먼저 받아 둔다.

1. 레포 변수 `DEV_ENABLED=false`를 넣어 병합 때 dev가 다시 생기지 않게 한다. 상태 확인 워크플로도 dev를 건너뛴다.
2. bootstrap 변수 `bedrock_stop_environments = ["main"]`으로 바꾸고 bootstrap을 다시 적용한다.
3. Terraform 밖에서 붙은 것을 앱 사용자에서 뗀다. 남아 있으면 사용자 삭제가 `DeleteConflict`로 실패한다.

   ```sh
   aws iam list-access-keys --user-name santacut-dev-app
   aws iam delete-access-key --user-name santacut-dev-app --access-key-id <키 ID>
   aws iam detach-user-policy --user-name santacut-dev-app --policy-arn arn:aws:iam::<계정>:policy/santacut-deny-bedrock   # 붙어 있을 때만
   ```

4. dev 백업 버킷의 모든 객체 버전을 지운다(콘솔에서 버킷 비우기).
5. 로컬에서 `modules/santacut_app/main.tf`의 `prevent_destroy`를 잠시 `false`로 바꾸고 `envs/dev`에서 `terraform destroy`한다. **이 변경은 커밋하지 않는다.** 운영 보호도 같은 줄이 맡고 있다.
6. `git checkout modules/santacut_app/main.tf`로 되돌린다.

다시 올릴 때는 `DEV_ENABLED`를 지우고 `bedrock_stop_environments`를 되돌린 뒤 병합하거나 `workflow_dispatch`로 실행한다.
