# 운영 절차

처음 설정은 1~7단계를 순서대로 한 번 한다. 8단계부터는 필요할 때 찾아 쓴다.

지금은 두 가지 절약 모드로 시작한다.

- **dev만**: 운영(`main`) 잡은 레포 변수 `MAIN_ENABLED=true`일 때만 돈다. 켜는 방법은 12절에 있다.
- **도메인 없음**: 도메인을 사기 전에는 `domain_name`을 비워 둔다. 접속은 고정 IP로 한다(2단계).

## 1. bootstrap (처음 한 번)

준비물: 관리자 권한 AWS 자격 증명(로컬), Terraform 1.17.

이 계정(466417120611)은 2026-11-16에 bootstrap을 적용했고, 상태는 S3 버킷 `santacut-tfstate-466417120611`에 있다. `backend.tf`도 커밋돼 있다. 다시 적용할 때는 아래처럼 한다.

```sh
cd bootstrap
terraform init -backend-config="bucket=santacut-tfstate-466417120611"
terraform apply
```

새 계정에 처음 적용할 때는 상태 버킷이 아직 없다. 순서는 다음과 같다.

1. `backend.tf`를 잠시 다른 이름으로 옮긴다.
2. `cp terraform.tfvars.example terraform.tfvars`로 예산과 알림 이메일을 채운다. 도메인은 산 뒤에 넣는다.
3. `terraform init && terraform apply`로 로컬 상태에 적용한다.
4. `backend.tf`를 되돌린다.
5. `terraform init -migrate-state -backend-config="bucket=<state_bucket 출력값>"`을 실행한다.
6. 로컬 `terraform.tfstate*`를 지운다.

apply 역할은 `envs/<env>/*` 키에만 쓸 수 있어서 CI가 bootstrap 상태를 바꾸지 못한다. 이후 권한, 예산, OIDC 설정을 바꿀 때는 관리자가 로컬에서 `terraform init -backend-config="bucket=..."` 후 다시 적용한다.

출력값은 다음 단계에서 쓴다: `state_bucket`, `name_servers`, `plan_role_arn`, `apply_role_arns`, `app_deploy_role_arns`, `kms_key_arns`. 도메인이 없으면 `zone_id`와 `name_servers`는 `null`이다.

### KMS 키

bootstrap은 환경마다 KMS 키 하나(`alias/santacut-dev`, `alias/santacut-main`)를 만든다(`bootstrap/kms.tf`).

- 백업 버킷 기본 암호화(SSE-KMS)와 앱 설정 파일(`config/app.env`)을 이 키로 암호화한다.
- `envs/<env>`는 별칭으로 키를 찾는다. 키가 없으면 plan이 실패하므로 **bootstrap을 먼저 로컬에서 적용한 뒤** CI가 dev를 적용하게 한다.
- 키 자동 교체를 켰다. 삭제 대기 기간은 최소인 7일이다.
- 앱 사용자는 S3를 거친 `kms:Decrypt`, `kms:GenerateDataKey`만 자기 환경 키에 쓸 수 있다. Terraform 역할에는 복호화 권한이 없다.

## 2. 도메인과 가비아 네임서버 위임

### 도메인 없이 쓰기

- `domain_name`을 비워 두면 Route 53 호스팅 영역과 A 레코드를 만들지 않는다. 비용은 0이다.
- 레포 변수 `DOMAIN_NAME`도 비워 둔다. CI가 빈 문자열을 넘겨도 도메인 없음으로 처리한다.
- 접속 주소는 각 환경 출력값 `app_url`이다. `http://<static_ip>` 형식이다.
- Caddy는 도메인이 있어야 TLS 인증서를 받는다. 그전에는 HTTP로만 접속한다. 앱 설정에서 `DOMAIN`을 비우면 앱 레포 Caddyfile이 `:80`으로 받는다. `PUBLIC_BASE_URL=http://<static_ip>`, `SESSION_SECURE=false`로 둔다.
- HTTP는 암호화되지 않는다. 실제 사용자 데이터는 도메인과 TLS를 갖춘 뒤 받는다.
- 상태 확인 워크플로(`health.yml`)는 `DOMAIN_NAME`이 비어 있으면 건너뛴다.

### 도메인을 산 뒤

코드는 고치지 않는다. 값만 넣고 다시 적용한다.

1. `bootstrap/terraform.tfvars`에 `domain_name`을 넣고 bootstrap을 다시 적용한다. 호스팅 영역이 생기고 apply 역할에 레코드 권한이 붙는다.
2. 가비아 도메인 관리 → 네임서버 설정에서 `name_servers` 출력값 4개를 등록한다. 반영까지 최대 하루가 걸릴 수 있다. `dig NS <도메인>`으로 확인한다.
3. 레포 변수 `DOMAIN_NAME`에 같은 도메인을 넣는다.
4. `workflow_dispatch`로 terraform 워크플로를 돌리거나 PR을 병합한다. 서버 A 레코드가 생긴다. dev는 `api-dev.<도메인>`, 운영은 `api.<도메인>`이다. 루트와 `www`는 프론트용으로 비워 둔다.
5. 로컬 앱 설정 파일에 `DOMAIN`, `ACME_EMAIL`을 채우고 `PUBLIC_BASE_URL=https://api-dev.<도메인>`(운영은 `api.<도메인>`), `SESSION_SECURE=true`로 바꾼다. `scripts/put-secrets.sh`로 다시 올리고 앱을 다시 띄운다(6절). Caddyfile은 고치지 않는다.

## 3. AI(Gemini)와 개인정보 국외 이전

앱은 Google Gemini 2.5 Flash로 점수를 낸다. AWS 쪽에 따로 활성화할 것은 없다. API 키는 Google AI Studio에서 받아 앱 설정의 `GEMINI_API_KEY`로 넣는다(6절 2).

### 개인정보 국외 이전 고지

Gemini API는 요청을 국외에서 처리한다. 개인정보 처리방침에 아래 항목을 모두 적는다(개인정보 보호법 제28조의8). 법률 검토는 따로 받는다.

- 이전받는 자: Google LLC(연락처 포함)
- 이전 국가: Google이 Gemini API를 처리하는 국가(특정 국가로 한정되지 않음을 명시)
- 이전 항목: 분석을 위해 보내는 대화 텍스트. 닉네임·세션 같은 식별 정보는 보내지 않는다
- 이전 시기와 방법: 분석 요청 시 암호화된 네트워크로 전송
- 이전 목적과 보유·이용 기간: AI 점수 산정. 보관 기간은 Gemini API 약관과 데이터 정책을 확인해 적는다
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
| `DOMAIN_NAME` | 서비스 도메인. 도메인을 사기 전에는 비워 둔다 |
| `SSH_PUBLIC_KEY` | 배포용 SSH 공개 키 |
| `SSH_ALLOWED_CIDRS` | HCL 목록 형식, /24 이상, 예: `["203.0.113.10/32"]`. SSH(22)만 제한한다. 80/443은 모두에게 열려 있어 프런트엔드 접속에는 영향이 없다 |
| `DEV_ENABLED` | 평소에는 비워 둔다. dev를 내렸을 때만 `false` |
| `MAIN_ENABLED` | 운영을 켤 때만 `true`. 비우면 dev만 plan·적용한다(12절) |
| `HEALTH_PATH` | 상태 확인 경로. 비우면 `/v3/api-docs` |

### Environment 두 개 (Settings → Environments)

두 Environment 모두 **배포 브랜치를 `main`으로 제한**한다. 제한이 없으면 아무 브랜치에서나 apply 역할을 맡을 수 있다.

- `dev`: 변수 `AWS_APPLY_ROLE_ARN` = `apply_role_arns.dev`
- `main`: 변수 `AWS_APPLY_ROLE_ARN` = `apply_role_arns.main`, **Required reviewers**에 운영 승인자를 넣는다. `MAIN_ENABLED`를 켜기 전에 만들면 된다.

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

PR을 병합하면 CI가 dev를 적용한다. `MAIN_ENABLED=true`이면 운영 plan을 만든 뒤 승인을 받아 main도 적용한다. 로컬에서 직접 적용할 때:

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
ls -ld /opt/santacut/releases /opt/santacut/backups /opt/santacut/aws   # aws는 700
systemctl is-enabled santacut-secrets    # enabled. 자격 증명을 넣기 전에는 조건 미충족으로 건너뛴다
stat -c '%a %U' /opt/santacut/backup.env /opt/santacut/backup.sh   # 600 ubuntu, 750 ubuntu
crontab -l                               # 0 * * * * /opt/santacut/backup.sh ...
swapon --show                            # /swapfile 1G
free -m
```

방화벽도 확인한다. IPv6 규칙이 없어야 한다.

```sh
aws lightsail get-instance-port-states --instance-name santacut-dev-app
```

## 6. 인스턴스 비밀값 설정

인스턴스 디스크에 평문으로 두는 비밀값은 앱 IAM 사용자 액세스 키 하나다(`/opt/santacut/aws/credentials`, 600, ubuntu). Lightsail에는 인스턴스 역할이 없어서 이 키가 유일한 시작 비밀값이다.

앱 설정(`.env`)은 환경별 KMS 키로 암호화해 S3에 두고, 부팅 때 tmpfs로 받는다. 레포, 워크플로, Terraform 코드와 상태 어디에도 비밀값이 없다.

한계도 있다. Compose `env_file` 값은 컨테이너 메타데이터(`docker inspect`, `/var/lib/docker`)에 남고 일일 스냅숏에도 들어간다. 디스크의 액세스 키로 `config/app.env`를 다시 받을 수도 있다. 이 방식의 이점은 비밀값을 한곳에서 바꾸고 KMS 사용 기록(CloudTrail)을 남기는 데 있다.

```text
운영자 PC --put-secrets.sh(SSE-KMS)--> s3://santacut-<env>-backup-<계정>/config/app.env
부팅 --> santacut-secrets.service --> /opt/santacut/bin/fetch-secrets.sh
     --> /run/santacut/app.env (tmpfs, 600, ubuntu) --> docker compose env_file
```

- 앱은 AWS 키를 쓰지 않는다. 자격 증명 파일은 `fetch-secrets.sh`와 백업 스크립트만 쓰고, 앱 컨테이너에는 넘기지 않는다. S3의 `app.env`에도 액세스 키를 넣지 않는다.
- `app.env`에 `GHCR_USER`, `GHCR_TOKEN`이 있으면 `fetch-secrets.sh`가 ubuntu로 `docker login ghcr.io --password-stdin`을 실행한다. 두 키는 빼고 나머지만 tmpfs에 쓰며, 토큰은 출력하지 않는다. 로그인 정보는 `~ubuntu/.docker/config.json`에 남는다.
- 앱 사용자는 `config/`를 읽기만 하고, `backups/`에만 쓴다.

### 1) 액세스 키 발급과 인스턴스 기록

키를 PC 파일이나 화면에 남기지 않도록, 발급 결과를 SSH로 인스턴스에 바로 쓴다. 관리자 자격 증명(`AWS_PROFILE=santacut`)으로 실행한다.

```sh
env=dev
ip=$(aws lightsail get-static-ip --static-ip-name santacut-$env-ip --query staticIp.ipAddress --output text)
aws iam create-access-key --user-name santacut-$env-app \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text |
  ssh ubuntu@$ip 'umask 077; read -r id secret
    printf "[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n" "$id" "$secret" > /opt/santacut/aws/credentials'
ssh ubuntu@$ip 'stat -c "%a %U" /opt/santacut/aws/credentials'   # 600 ubuntu
```

키 권한은 백업 한 번으로 확인한다. `/opt/santacut/backup.sh`가 `Off-host backup verified`로 끝나야 한다. 첫 배포 전이면 건너뛰었다는 줄만 나온다.

### 2) 앱 설정을 암호화해 올리기 (운영자 PC)

앱 레포 `backend/ci-cd/deploy/.env.example`의 키를 채운다. 변수 이름은 앱 레포 설정과 맞춘다. **`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`는 넣지 않는다.**

```sh
# 도메인이 없으면 DOMAIN, ACME_EMAIL을 비우고 PUBLIC_BASE_URL을 http://<static_ip>로 둔다.
DOMAIN=
ACME_EMAIL=
PUBLIC_BASE_URL=http://<static_ip>
SESSION_SECURE=false            # 도메인과 HTTPS를 쓸 때만 true
APP_SEASON_YEAR=2026
# Google AI Studio에서 받은 Gemini API 키. 앱은 이 키가 없으면 뜨지 않는다.
GEMINI_API_KEY=<Gemini API 키>
# dev에만 둔다. 프롬프트 관리 API(/v1/admin/prompts)를 켠다. main에서는 이 줄을 빼 404로 둔다.
PROMPT_ADMIN_ENABLED=true
# 비공개 GHCR 이미지를 받을 때만 넣는다. read:packages 권한만 준 토큰을 쓰고, 따옴표 없이 적는다.
# 앱 컨테이너에는 넘어가지 않는다(위 fetch-secrets.sh 설명).
GHCR_USER=<GitHub 사용자>
GHCR_TOKEN=<read:packages 토큰>
```

이 파일을 권한 600으로 만들고 올린다. 스크립트는 WSL, Linux, macOS에서 돌린다. Git Bash는 파일 권한을 표현하지 못해 항상 거부된다.

```sh
chmod 600 ~/santacut-dev.env
AWS_PROFILE=santacut bash scripts/put-secrets.sh dev ~/santacut-dev.env
```

- 스크립트는 `aws s3 cp --sse aws:kms --sse-kms-key-id <키 ARN>`으로 올린다. 별칭(`alias/santacut-<env>`)을 키 ARN으로 바꿔 넘긴다. 버킷 정책이 이 환경 키 ARN을 요구하기 때문이다.
- 값은 출력하지 않고 암호화 메타데이터(`aws:kms`, 키 ARN)만 보여 준다.
- 올린 뒤 로컬 파일은 비밀번호 관리자로 옮기고 지운다.

### 3) 인스턴스에서 받기

재부팅하면 `santacut-secrets.service`가 Docker보다 먼저 받는다. 지금 바로 받으려면 서비스를 다시 시작한다.

```sh
sudo systemctl restart santacut-secrets
systemctl status santacut-secrets --no-pager     # fetch-secrets: OK (GHCR 키가 있으면 GHCR 로그인 OK도)
stat -c '%a %U' /run/santacut/app.env             # 600 ubuntu
findmnt -no FSTYPE -T /run/santacut               # tmpfs
```

Compose는 이 파일을 읽는다. 앱 레포 `deploy/compose.yml`의 앱 서비스가 `env_file: /run/santacut/app.env`이고, `deploy.sh`·`backup.sh`의 보간용 `--env-file`도 같은 경로다. `/opt/santacut/.env`는 더 이상 쓰지 않는다.

Compose는 `env_file`을 `up`할 때만 읽는다. 설정을 바꿨으면 `docker compose --env-file /run/santacut/app.env -f /opt/santacut/current/deploy/compose.yml up -d --force-recreate`로 컨테이너를 다시 만든다.

### 512MB 번들의 메모리

기본 번들 `nano_3_0`은 메모리가 512MB다. Caddy와 Spring을 함께 돌리기에 빠듯하다.

- 첫 부팅 스크립트가 1GB 스왑(`/swapfile`)을 만들고 `vm.swappiness=10`으로 둔다. 스왑은 비상용이다.
- 앱 레포 Compose가 메모리를 나눈다. 앱 `mem_limit: 400m`(JVM `-Xmx256m`, SerialGC, `-Xss512k`, `ExitOnOutOfMemoryError`), Caddy `mem_limit: 64m`.
- 컨테이너가 OOM으로 죽거나 응답이 느려지면 사양을 올린다. `bundle_id`를 바꾸고 9절의 인스턴스 교체 절차를 따른다.

### `/opt/santacut/backup.env` (권한 600, 소유자 ubuntu)

첫 부팅 스크립트가 Terraform의 환경 KMS 키 ARN과 백업 버킷 이름으로 이 파일을 만든다. 손으로 쓸 일은 없고, 아래는 확인용이다. `backup.sh`는 이 파일을 `source`하고 rclone을 직접 실행한다. 이 파일에는 비밀값이 없다. rclone은 `AWS_SHARED_CREDENTIALS_FILE`이 가리키는 자격 증명 파일을 읽는다.

- 앱 사용자에게는 버킷 생성 권한이 없으므로 `no_check_bucket=true`가 필요하다.
- 버킷 정책이 SSE-KMS와 이 환경 키 ARN을 요구한다. 그래서 `server_side_encryption`, `sse_kms_key_id`가 필요하다. 키 ARN은 환경 출력값 `kms_key_arn`이다. 값에 콜론이 있어 작은따옴표로 감싼다.
- `upload_cutoff=5G`로 멀티파트 업로드를 피한다. 멀티파트의 파트 업로드 요청이 버킷 정책의 암호화 헤더 조건에 걸리는지는 미확인이다. SQLite 백업은 작아서 한 번에 올라간다.

```sh
export AWS_SHARED_CREDENTIALS_FILE=/opt/santacut/aws/credentials
BACKUP_REMOTE=":s3,provider=AWS,env_auth=true,region=ap-northeast-2,no_check_bucket=true,server_side_encryption='aws:kms',sse_kms_key_id='<kms_key_arn>',upload_cutoff=5G:<backup_bucket>/backups/sqlite"
```

### 키 교체

액세스 키는 자격 증명 파일 한 곳에만 있다. 프로젝트가 12/31에 끝나므로 정기 교체는 하지 않고, 유출이 의심될 때만 바꾼다.

1. 1)의 명령으로 새 키를 발급해 자격 증명 파일을 덮어쓴다.
2. `sudo systemctl restart santacut-secrets` 후 위의 `up -d --force-recreate`로 앱을 다시 만든다.
3. 백업 한 번(`/opt/santacut/backup.sh`)이 되는지 확인한다.
4. 예전 키를 지운다: `aws iam delete-access-key --user-name santacut-<env>-app --access-key-id <예전 키 ID>`.

### 이미 있는 인스턴스에 적용하기 (한 번)

인스턴스에는 `ignore_changes = [user_data]`가 걸려 있다. 첫 부팅 스크립트를 고쳐도 **지금 돌고 있는 인스턴스에는 반영되지 않는다.** 2026-11 KMS 전환 전에 만든 인스턴스(dev)는 아래를 한 번 한다.

1. 첫 부팅 스크립트를 렌더링해 다시 실행한다. 스크립트는 여러 번 실행해도 결과가 같다. 다만 `apt-get install`이 Docker를 새 버전으로 올리며 다시 시작할 수 있으니 트래픽이 적을 때 한다.

   ```sh
   env=dev; acct=466417120611
   kms=$(aws kms describe-key --key-id alias/santacut-$env --query KeyMetadata.Arn --output text)
   sed -e 's/\$\${/${/g' -e "s/\${backup_bucket}/santacut-$env-backup-$acct/" -e "s|\${kms_key_arn}|$kms|" \
     modules/santacut_app/cloud-init.sh > /tmp/santacut-init.sh
   scp /tmp/santacut-init.sh ubuntu@$ip:/tmp/
   ssh ubuntu@$ip 'sudo bash /tmp/santacut-init.sh; tail -n 1 /var/log/santacut-init.log; rm /tmp/santacut-init.sh'
   ```

2. 위 1)~3)을 한다. 새 키를 발급했다면, 예전 키는 평문 `.env`에 있었으니 지운다.
3. 예전 평문 파일을 없앤다: `shred -u /opt/santacut/.env` 후 `ln -s /run/santacut/app.env /opt/santacut/.env`. `backup.env`는 위 형식으로 다시 쓴다(액세스 키 줄 삭제).
4. age는 더 이상 쓰지 않는다: `sudo apt-get remove -y age`. 비밀번호 관리자의 age 개인키는 예전 `sqlite/` 백업이 남아 있는 동안만 보관한다.
5. 예전 `sqlite/` 접두사의 age 백업은 새 수명 주기 규칙(`backups/`)에 걸리지 않는다. 새 백업이 `backups/`에 쌓이는 것을 확인한 뒤 지운다.

## 7. 앱 배포 연동 (앱 레포에서 할 일)

- 앱 레포 GitHub Environment 이름을 `dev`, `main`으로 맞추고, 배포 브랜치를 `dev`는 `develop`, `main`은 `main`으로 제한한다. dev는 `develop` 푸시마다 자동 배포된다(앱 레포 `backend/docs/deployment.md`). 변수 `AWS_DEPLOY_ROLE_ARN`에 `app_deploy_role_arns.<env>`를 넣는다.
- 완료(2026-11-16): 앱은 Bedrock 대신 Google Gemini 2.5 Flash를 부른다. 키는 `app.env`의 `GEMINI_API_KEY`다. AI 비용 보호는 10절에 있다.
- 완료: 릴리스 묶음(tar)에 `scripts/deploy.sh`와 `scripts/backup.sh`가 함께 들어간다.
- 완료: `backup.sh`에서 age 암호화를 뺐다. SQLite `.backup` 결과를 `$BACKUP_REMOTE`(`backups/sqlite`)에 올리면 S3가 KMS로 암호화한다. 올린 뒤 내려받아 대조하고, 로컬 복사본은 2일만 둔다. `BACKUP_AGE_RECIPIENT`는 없다.
- 완료: Compose와 `deploy.sh`, `backup.sh`는 앱 설정을 `/run/santacut/app.env`에서 읽는다(6절 3).
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

확인(2026-11-17, dev): 열기는 22번 규칙에 CIDR을 더하고, 닫기는 지정한 CIDR만 뺀다. 운영자 CIDR은 배포 뒤에도 남는다. 앱 레포 `deploy-dev` 잡은 닫은 뒤 `get-instance-port-states`로 러너 CIDR이 빠졌는지 확인하고, 운영자 CIDR(`DEV_OPERATOR_SSH_CIDR`)이 없으면 다시 연다.

공개 포트 규칙(`aws_lightsail_instance_public_ports`)을 바꾸는 apply는 리소스를 교체하면서 80/443을 몇 초 닫는다. 운영자 CIDR 변경은 트래픽이 적은 시간에 하고, 앱 배포 중에는 인프라 apply를 돌리지 않는다.

### 백업 스크립트와 cron (자동)

첫 부팅 스크립트가 아래를 만든다. 손으로 설치할 일은 없다.

- `/opt/santacut/backup.env`: 6절 형식. 환경 KMS 키 ARN과 백업 버킷은 Terraform이 넣는다.
- `/opt/santacut/backup.sh`: 현재 릴리스의 `scripts/backup.sh`를 `bash`로 부르는 진입점이다. 본체가 릴리스 묶음에 들어 있어 따로 복사하지 않아도 늘 최신이다. 첫 배포 전에는 건너뛰었다는 줄만 남기고 끝난다.
- ubuntu crontab: `0 * * * * /opt/santacut/backup.sh >> /opt/santacut/backups/backup.log 2>&1`

`deploy.sh`는 두 번째 배포부터 이 진입점으로 배포 전 백업을 뜬다.

## 8. 관측과 알람

### 자동 확인 (GitHub Actions)

`.github/workflows/health.yml`이 매시간 두 환경의 HTTP 응답과 S3 백업 신선도(마지막 백업 3시간 이내)를 확인한다. 인스턴스 상태 알람은 컨테이너가 죽어도 울리지 않기 때문에 이 확인이 필요하다.

- 실패 메일은 이 워크플로의 cron을 마지막으로 고친 사용자에게만 간다. 그 사용자의 GitHub 알림 설정에서 Actions 실패 메일이 켜져 있는지 확인한다.
- 공개 레포는 60일 동안 활동이 없으면 스케줄 워크플로가 자동으로 꺼진다. 주간 점검에서 `gh workflow view health`로 켜져 있는지 보고, 꺼졌으면 `gh workflow enable health`로 켠다.

### Lightsail 알람

`aws_lightsail_*`에는 알람 리소스가 없어 CLI로 한 번 건다(알람 요금은 적용 전에 요금 페이지에서 확인한다). 연락처 등록 후 받은 **인증 메일의 링크를 눌러야** 알람이 발송된다. dev만 쓰는 동안은 아래 반복문에서 `main`을 뺀다.

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
- **S3 백업**: `backup.sh`가 SQLite를 `.backup`으로 떠서 `backups/sqlite/`에 올린다. 버킷이 환경별 KMS 키로 암호화한다(SSE-KMS, 버킷 키 사용). 객체는 14일 뒤 이전 버전이 되고, 그로부터 7일 뒤 영구 삭제된다(최대 21일 보관). 수명 주기 규칙은 `backups/`에만 걸려 있어 `config/app.env`는 만료되지 않는다.

### S3 백업에서 SQLite 복원

출시 전에 dev에서 한 번 리허설한다.

1. 복원할 백업을 내려받는다(인스턴스에서).

   ```sh
   set -a; . /opt/santacut/backup.env; set +a
   rclone lsl "$BACKUP_REMOTE" | tail -5
   rclone copyto "$BACKUP_REMOTE/santacut-<시각>.sqlite" /tmp/restore.sqlite
   ```

2. 복호화는 S3가 한다. 앱 사용자에게 S3 경유 `kms:Decrypt`가 있어 따로 할 일이 없다. 2026-11 이전의 `sqlite/*.age` 백업만 PC에서 `age -d -i <개인키 파일>`로 푼다.
3. 무결성을 확인한다: `sqlite3 /tmp/restore.sqlite 'PRAGMA integrity_check;'` 결과가 `ok`.
4. 앱을 멈춘 뒤 볼륨의 DB를 바꾼다.

   ```sh
   cd /opt/santacut/current
   docker compose --env-file /run/santacut/app.env -f deploy/compose.yml stop app
   vol=$(docker volume inspect santacut_santacut_data --format '{{ .Mountpoint }}')
   sudo cp "$vol/santacut.db" "/opt/santacut/backups/before-restore-$(date -u +%Y%m%dT%H%M%SZ).db"
   sudo install -o 10001 -g 10001 -m 0600 /tmp/restore.sqlite "$vol/santacut.db"   # 앱 컨테이너 사용자(UID 10001)
   sudo rm -f "$vol/santacut.db-wal" "$vol/santacut.db-shm"
   docker compose --env-file /run/santacut/app.env -f deploy/compose.yml start app
   ```

5. 쓰기가 되는지 확인한다: 참가자 등록이나 분석 제출 같은 쓰기 요청 하나가 성공해야 한다.

인스턴스를 통째로 잃었으면(자동 스냅숏도 없음) 새 인스턴스를 `terraform apply`로 만들고 5~7단계를 다시 한 뒤 위 복원을 한다.

### 인스턴스 교체 (사양 올리기, 장애 복구)

인스턴스 이름과 번들은 바꾸면 재생성되는 속성이고 `prevent_destroy`가 걸려 있어, Terraform만으로는 교체할 수 없다. 아래 순서를 지킨다. 먼저 dev에서 리허설한다.

1. 스냅숏을 준비한다.
   - **사양 올리기(인스턴스 정상)**: Caddy를 멈춰 요청을 끊고, 앱이 살아 있는 동안 마지막 백업을 올린 뒤(`backup.sh`는 실행 중인 앱 컨테이너 안에서 백업을 뜬다) 앱을 멈추고 지금 시점 수동 스냅숏을 뜬다.

     ```sh
     compose="docker compose --env-file /run/santacut/app.env -f /opt/santacut/current/deploy/compose.yml"
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
9. `/run/santacut/app.env`는 tmpfs라 스냅숏에 없다. 부팅 때 `santacut-secrets`가 다시 받으니 `systemctl status santacut-secrets`로 확인한 뒤 앱을 다시 띄운다. 스냅숏은 앱을 수동으로 멈춘 상태에서 떴기 때문에 `restart: unless-stopped` 정책으로는 자동으로 올라오지 않는다.

   ```sh
   docker compose --env-file /run/santacut/app.env -f /opt/santacut/current/deploy/compose.yml start app caddy
   curl -fsS https://api.<도메인>/v3/api-docs -o /dev/null && echo OK
   ```

10. 8절의 Lightsail 알람이 남아 있는지 `aws lightsail get-alarms`로 확인하고, 없으면 다시 건다.
11. 장애 복구였다면 스냅숏 시점의 SQLite는 최대 하루 전이다. 더 최신인 S3 백업으로 덮어쓸지 판단하고, 덮어쓰면 위 복원 절차를 따른다.

## 10. AI 비용 보호 (Gemini)

Gemini 비용은 AWS 청구서에 잡히지 않는다. AWS 계정 예산(`santacut-monthly`)은 Lightsail, S3 같은 AWS 비용만 본다. AI 비용은 아래 두 가지로 막는다.

1. **앱 자체 한도**: 앱이 Gemini 사용액을 하루 0.5달러, 한 달 9달러에서 끊는다. 한도 설정은 앱 레포에 있다.
2. **Google Cloud 결제 예산 알림**: 운영자가 Google Cloud 콘솔(결제 → 예산 및 알림)에서 Gemini API 키가 속한 프로젝트에 예산을 만들고 알림 이메일을 건다. 알림만 보내고 호출은 막지 않는다. Terraform이 관리하지 않으므로 프로젝트 종료 때 직접 지운다.

## 11. dev 내리기

dev가 당분간 필요 없으면 아래 순서로 내린다. dev 데이터는 사라지므로 필요한 백업을 먼저 받아 둔다.

1. 레포 변수 `DEV_ENABLED=false`를 넣어 병합 때 dev가 다시 생기지 않게 한다. 상태 확인 워크플로도 dev를 건너뛴다.
2. Terraform 밖에서 붙은 것을 앱 사용자에서 뗀다. 남아 있으면 사용자 삭제가 `DeleteConflict`로 실패한다.

   ```sh
   aws iam list-access-keys --user-name santacut-dev-app
   aws iam delete-access-key --user-name santacut-dev-app --access-key-id <키 ID>
   ```

3. dev 백업 버킷의 모든 객체 버전을 지운다(콘솔에서 버킷 비우기).
4. 로컬에서 `modules/santacut_app/main.tf`의 `prevent_destroy`를 잠시 `false`로 바꾸고 `envs/dev`에서 `terraform destroy`한다. **이 변경은 커밋하지 않는다.** 운영 보호도 같은 줄이 맡고 있다.
5. `git checkout modules/santacut_app/main.tf`로 되돌린다.

다시 올릴 때는 `DEV_ENABLED`를 지운 뒤 병합하거나 `workflow_dispatch`로 실행한다.

## 12. 운영(main) 켜기

처음에는 dev만 쓴다. 운영 잡(`plan-main`, `apply-main`, PR의 main plan)과 main 상태 확인은 `MAIN_ENABLED=true`일 때만 돈다.

1. 4단계의 `main` Environment를 만들고 승인자를 건다.
2. 운영 고정비만큼 bootstrap `monthly_budget_usd`를 올린다. README 비용 표에서 두 환경 금액을 확인한다.
3. 레포 변수 `MAIN_ENABLED=true`를 넣는다.
4. `workflow_dispatch`로 실행하거나 PR을 병합한다. dev 적용 뒤 운영 plan이 나오고, 승인하면 적용된다.
5. 5~8단계의 첫 부팅 확인, 비밀값, 배포 연동, 알람을 main에도 한다.

운영 도메인은 서비스 도메인 그 자체다. 도메인 없이 켜면 main도 고정 IP로 접속한다.

## 13. 프로젝트 종료(12/31) 철거 절차

프로젝트는 2026-12-31에 끝난다. 모든 리소스에 `ExpiresOn=2026-12-31` 태그가 있다(변수 `project_end_date`). 철거는 관리자 자격 증명으로 로컬에서 한다. CI가 다시 만들지 않게 먼저 멈춘다.

1. **CI 멈추기**: 레포 변수 `DEV_ENABLED=false`를 넣고 `MAIN_ENABLED`는 비운다. `gh workflow disable health`, `gh workflow disable terraform`을 실행한다.
2. **마지막 백업 받기(원할 때)**: 인스턴스에서 `/opt/santacut/backup.sh`를 한 번 돌리고 관리자 PC로 받는다. S3가 복호화해 주므로 받은 파일은 평문 SQLite다. 안전한 곳에 둔다.

   ```sh
   aws s3 cp s3://santacut-<env>-backup-466417120611/backups/sqlite/ ./final-backup/ --recursive
   ```

3. **Terraform 밖에서 만든 것 지우기**: 앱 사용자 액세스 키(11절 2), Google Cloud 결제 예산 알림(10절), Lightsail 알람과 연락처(`aws lightsail delete-alarm`, `delete-contact-method`), 수동 스냅숏(`aws lightsail get-instance-snapshots` 후 `delete-instance-snapshot`). 자동 스냅숏은 인스턴스와 함께 지워진다.
4. **`prevent_destroy` 풀기**: 아래 파일의 `prevent_destroy = true`를 로컬에서만 `false`로 바꾼다. **커밋하지 않는다.**
   - `modules/santacut_app/main.tf` (Lightsail 인스턴스)
   - `bootstrap/state.tf` (상태 버킷)
   - `bootstrap/dns.tf` (Route 53 호스팅 영역, 도메인이 있을 때만)
5. **버전 관리 버킷 비우기**: 모든 버전과 삭제 마커를 지워야 `destroy`가 된다. 콘솔의 버킷 비우기가 가장 쉽다. 아래 CLI는 한 번에 1000개까지만 지운다. 목록이 빌 때까지 반복한다. 빈 목록이면 `delete-objects`가 오류를 내며 끝난다.

   ```sh
   b=santacut-<env>-backup-466417120611
   aws s3api list-object-versions --bucket $b \
     --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId} | [:1000], Quiet: `true`}' > /tmp/del.json
   aws s3api delete-objects --bucket $b --delete file:///tmp/del.json
   ```

6. **`terraform destroy` 순서는 main → dev → bootstrap이다.** 환경 버킷이 bootstrap의 KMS 키와 상태 버킷에 기대므로 bootstrap은 마지막이다.

   ```sh
   bucket=santacut-tfstate-466417120611
   terraform -chdir=envs/main init -backend-config="bucket=$bucket" && terraform -chdir=envs/main destroy   # main을 켠 적이 있을 때만
   terraform -chdir=envs/dev init -backend-config="bucket=$bucket" && terraform -chdir=envs/dev destroy
   ```

7. **bootstrap 철거**: bootstrap 상태가 지울 상태 버킷 안에 있어 먼저 로컬로 옮긴다.
   1. `bootstrap/backend.tf`를 다른 이름으로 옮기고 `terraform -chdir=bootstrap init -migrate-state`로 상태를 로컬로 가져온다.
   2. 5번 명령으로 상태 버킷(`santacut-tfstate-466417120611`)을 비운다.
   3. `terraform -chdir=bootstrap destroy`를 실행한다.
8. **KMS 키 삭제 대기**: `destroy`는 키를 바로 지우지 않고 7일 동안 삭제 대기로 둔다. 대기 중에도 소액이 청구될 수 있다(미확인, 두 키 7일분이면 1달러 미만). 그동안은 `aws kms cancel-key-deletion`으로 되살릴 수 있다. `aws kms describe-key --key-id <키 ID> --query KeyMetadata.KeyState`가 `PendingDeletion`이면 된다.
9. **남은 것 확인**: Lightsail 콘솔에 인스턴스, 고정 IP, 스냅숏이 없는지 본다. 고정 IP는 인스턴스에 붙어 있지 않으면 요금이 나간다.
10. **IAM Identity Center 사용자(원할 때)**: 운영자 SSO 사용자와 권한 세트 할당을 콘솔에서 지운다. 지우면 이 계정에 SSO로 로그인할 수 없으니 맨 마지막에 한다. 루트 계정은 남긴다.
11. **1월에 비용 확인**: 12월 사용분은 1월 초에 청구된다. 1월 중순에 Cost Explorer에서 서비스별 비용이 0인지 본다. 예산 알림 기간은 2027-01-31까지지만(`budget_end`), bootstrap을 지우면 예산도 사라지므로 직접 확인한다.
