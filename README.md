# santacut-infra

산타컷 서비스의 AWS 인프라를 Terraform으로 관리한다. 앱 코드는 [`yooni9ue/santacut`](https://github.com/yooni9ue/santacut)에 있다.

## 구성

```
GitHub Actions(OIDC) ──plan/apply──▶ Terraform 상태(S3, 네이티브 잠금)

사용자 ──▶ Route 53 ──▶ Lightsail 고정 IP ──▶ Lightsail 인스턴스(환경마다 1대)
                                              ├─ Caddy(TLS) → Spring Boot 앱
                                              ├─ SQLite(디스크, 매일 자동 스냅숏)
                                              └─ backup.sh ──▶ S3 백업 버킷(age 암호화)
                                   앱 ──▶ Amazon Bedrock(Claude Haiku 5.5, Global 추론)
```

| 디렉터리 | 내용 |
| --- | --- |
| `bootstrap/` | 계정에 한 번 만드는 공용 리소스: 상태 버킷, GitHub OIDC 역할(plan, 환경별 apply, 앱 배포), Route 53 호스팅 영역, 월 예산 알림 |
| `modules/santacut_app/` | 환경 하나: Lightsail 인스턴스·고정 IP·방화벽·자동 스냅숏, 도메인 A 레코드, 백업 버킷, 앱 IAM 사용자 |
| `envs/dev`, `envs/main` | 모듈을 조립하는 환경별 루트. 운영 환경 이름은 `main`이다 |

## 브랜치와 적용 흐름

브랜치는 `main` 하나다. PR을 올리면 두 환경을 plan하고, `main`에 병합되면 dev에 자동 적용한 뒤 운영(main)은 GitHub Environment 승인을 받고 적용한다.

## 예상 월 비용

| 항목 | 월 비용(USD) | 근거 |
| --- | --- | --- |
| Lightsail 2GB 번들(2 vCPU, 60GB SSD, 3TB 전송, 고정 IP 포함) × 2 환경 | 24 | [Lightsail 요금](https://aws.amazon.com/lightsail/pricing/), 12 × 2 |
| Lightsail 자동 스냅숏 | 약 1~3 | GB당 0.05, 증분 저장이라 실제 사용량에 따라 다름(추정) |
| Route 53 호스팅 영역 | 0.5 | |
| S3(상태·백업) | 1 미만 | 수 GB 이하 |
| GitHub Actions | 0 | 공개 레포 표준 러너 무료. 상태 확인은 매시간 2잡 |
| **고정비 합계** | **약 26~28** | |
| Bedrock Claude Haiku 5.5 | 상한 약 3~4(추정) | 아래 계산 |

Bedrock 상한 계산: 하루 호출 한도 100회 × 30일 × 2환경 = 월 6,000회. 호출당 입력 3,000토큰·출력 500토큰으로 가정하고, Anthropic API 단가(100만 토큰당 입력 0.10, 출력 0.50)를 쓰면 회당 약 0.00055달러, 월 약 3.3달러다. Bedrock 단가와 서울 리전 Global 프로파일 제공 여부는 미확인이라 첫 달 Cost Explorer로 확인한다.

예산: 계정 전체 40달러(고정비 28 + Bedrock 예산 10 + 여유), Bedrock만 따로 10달러(`bootstrap/budget.tf`).

Lightsail은 인스턴스를 멈춰도 요금이 나간다. dev가 필요 없으면 dev 스택을 내린다(`docs/operations.md` 11절).

## 처음 설정과 운영

[`docs/operations.md`](docs/operations.md)를 따른다.

## 검증

```sh
terraform fmt -check -recursive
for d in bootstrap envs/dev envs/main; do terraform -chdir=$d init -backend=false && terraform -chdir=$d validate; done
terraform -chdir=modules/santacut_app init -backend=false && terraform -chdir=modules/santacut_app test
```
