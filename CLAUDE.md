# 산타컷 인프라 작업 지침

산타컷 서비스의 AWS 인프라를 Terraform으로 관리하는 레포다. 앱 코드는 `yooni9ue/santacut` 레포에 있다.

## 구성 결정 (2026-11-15 확정)

| 항목 | 결정 |
| --- | --- |
| 실행 | 환경마다 AWS Lightsail 인스턴스 한 대. 앱 레포의 Docker Compose(Caddy + Spring)와 `deploy.sh`를 그대로 쓴다 |
| DB | SQLite 유지. 인스턴스 디스크에 두고 Lightsail 자동 스냅숏과 S3 백업(SSE-KMS)으로 지킨다 |
| AI | Google Gemini 2.5 Flash(2026-11-16 Bedrock에서 바꿈). 서버에서 모델을 돌리지 않는다. 키는 S3 `config/app.env`에 둔다 |
| 분석 진행 | 폴링(GET 2~3초 간격). SSE를 쓰지 않는다 |
| 계정 | dev와 main은 같은 AWS 계정에서 이름 접두사(`santacut-dev-`, `santacut-main-`)와 IAM 범위로 나눈다 |
| 리전 | 서울(`ap-northeast-2`) |

## 원칙

- 인스턴스는 환경마다 한 대만 둔다. 로드 밸런서, NAT 게이트웨이, 관리형 DB처럼 월 고정비가 드는 리소스를 더하려면 이유와 월 비용을 PR에 적는다.
- 비밀값(액세스 키, `.env` 값)은 Terraform 코드와 상태, 레포, 워크플로에 넣지 않는다. 액세스 키는 사람이 발급해 인스턴스의 `/opt/santacut/aws/credentials`에 바로 쓴다. 앱 설정은 KMS로 암호화해 S3 `config/app.env`에 두고 부팅 때 tmpfs로 받는다(`docs/operations.md` 6절).
- 프로젝트는 2026-12-31에 끝난다. 새 리소스는 짧은 수명과 깨끗한 철거(`docs/operations.md` 13절)를 기준으로 고른다.
- Lightsail 인스턴스는 IAM 역할을 쓸 수 없다. 앱 권한은 환경별 IAM 사용자에게 백업 버킷 접근만 준다.
- 사람이 읽는 텍스트(주석, 설명, 문서, 커밋 메시지)는 한국어로 쓴다. 리소스 이름, 변수명, 태그 키는 영어다.

## 구조와 브랜치 전략

- `bootstrap/`: 계정에 한 번만 만드는 공용 리소스(상태 버킷, GitHub OIDC 역할, 환경별 KMS 키, Route 53 호스팅 영역, 예산 알림). 처음에는 로컬 상태로 적용하고, 그 뒤 S3 상태(`bootstrap/backend.tf`)로 옮긴다.
- `envs/dev`, `envs/main`: 두 환경을 디렉터리로 나란히 둔다. 각 디렉터리가 하나의 루트 모듈이고 원격 상태 키가 따로 있다. 운영 환경 이름은 `main`이다.
- `modules/santacut_app/`: 두 환경이 같이 쓰는 모듈. 환경 디렉터리는 모듈을 조립하고 환경별 값만 가진다.
- 브랜치는 `main` 하나만 쓴다(트렁크 기반). PR에서 두 환경 모두 `plan`하고, `main` 병합 후 `dev`에 먼저 적용한 다음 `main` 환경은 GitHub Environment 승인 후 적용한다. 환경별 브랜치를 만들지 않는다.

## 검증

```sh
terraform fmt -check -recursive
for d in bootstrap envs/dev envs/main; do terraform -chdir=$d init -backend=false && terraform -chdir=$d validate; done
terraform -chdir=modules/santacut_app init -backend=false && terraform -chdir=modules/santacut_app test
```

커밋 전에 위 명령이 통과해야 한다. 커밋 메시지는 `타입(범위): 한국어 요약` 형식이다.

## 인프라 리뷰 패널

인프라 변경은 아래 6명이 독립적으로 검토한다. 리뷰어는 서로의 결과를 보지 않고, 코드를 고치지 않고 판정만 한다. 기능 지원 여부와 가격은 AWS·Terraform 공식 문서로 확인하고 출처를 단다. 확인하지 못한 수치는 "미확인"으로 표시한다.

| 리뷰어 | 역할 | 관점 |
| --- | --- | --- |
| 인프라 1 | 인프라 전문가 | 전체 아키텍처와 비용: 인스턴스 사양, 월 고정비, AI 호출 비용, 사용자 체감 성능 |
| 인프라 2 | 인프라 전문가 | 상태와 데이터: SQLite 디스크, 스냅숏·백업·복구 절차, 환경 간 데이터 분리 |
| 인프라 3 | 인프라 전문가 | Terraform 구조와 운영: 모듈 설계, 원격 상태·잠금, 버전 고정, CI/CD, 관측·알람·예산 |
| AWS 1 | AWS 전문가 | 컴퓨트와 요청 처리: Lightsail 번들·방화벽·고정 IP, 컨테이너 실행, 배포·롤백 |
| AWS 2 | AWS 전문가 | AI 연동: Gemini API 키 관리, AI 비용 상한(앱 한도와 Google Cloud 예산 알림), 개인정보 국외 이전 |
| AWS 3 | AWS 전문가 | 보안·네트워크·도메인: IAM 최소 권한, OIDC, 비밀값, SSH 노출, DNS·TLS, 개인정보 국외 이전 |

### 판정 방법

- 위반이나 위험마다 `파일:줄`, 무엇이 왜 문제인지, 고치는 방법, 심각도(치명·주요·사소)를 적는다.
- 이유 없이 월 고정비 리소스가 들어오거나 비밀값이 코드·상태에 들어가면 치명으로 본다.
- 점수는 100점에서 시작해 심각도(치명 -10, 주요 -5, 사소 -2)만큼 뺀다. 6명 모두 100점이 될 때까지 수정과 재검토를 반복한다.
