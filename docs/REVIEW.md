# 설계 검토 결과 — 원본 설계도 대비 결함과 수정 내역

원본: `aws-observability-portfolio-design.md` (서버리스 관측성 & 자가복구 설계 초안)
검토 방법: 설계 문서 정독 → 실제 코드로 구현 → `terraform validate` / 실제 계정 대상 `terraform plan`(읽기 전용) / `pytest` 로 검증하며 드러난 문제까지 포함.

심각도: **치명** = 그대로 만들면 동작하지 않거나 apply 실패 · **높음** = 비용 초과·보안 위험 · **중간** = 설계 품질/정확성 · **낮음** = 문서

## 치명 — 그대로 구현하면 동작하지 않음

| # | 원본 설계 | 문제 | 수정 |
|---|---|---|---|
| 1 | HTTP API로 비용 절감 + X-Ray로 API GW→Lambda→DynamoDB 체인 시각화 | **X-Ray 액티브 트레이싱은 REST API만 지원.** 두 요구가 상충 | REST API 채택. 저트래픽이라 요금 차이는 월 수십 원 수준이고, 사용량 계획(쿼터)도 REST만 지원해 비용 방어에도 필요 |
| 2 | "이전 정상 버전으로 Lambda 별칭 롤백" | API Gateway가 `$LATEST`를 호출하면 alias를 바꿔도 트래픽이 안 바뀜. 버전 발행 절차도 없음 | API 통합 URI를 **alias `live`** 로, CI가 매 배포마다 `publish-version` |
| 3 | (장애 시연 방법 없음) | 자가복구를 증명할 수단이 없음. 장애를 SSM/런타임 설정으로 주입하면 롤백해도 장애가 남음 | `FAULT_RATE` 환경변수 + **Lambda 버전이 환경변수까지 스냅샷**한다는 점을 이용 → 장애 버전을 되돌리면 장애도 사라짐 (`scripts/chaos_bad_release.sh`) |
| 4 | 롤백 대상 결정 로직 없음 | "이전 정상 버전"이 몇 번인지 알 방법이 없고, 롤백 후 같은 알람이 다시 울리면 나쁜 버전으로 되돌아갈 수 있음(플래핑) | SSM `stable-version`/`previous-version` bookkeeping. 롤백 후 previous를 비워 플래핑 차단. 단위 테스트로 검증 |
| 5 | (계정 상태 미고려) | 실제 계정에 GitHub OIDC Provider가 **이미 존재** → 신규 생성 시 apply 실패 (URL당 1개) | `create_oidc_provider` 변수로 기존 Provider 재사용 |
| 6 | (구현 단계) | 테스트에서 발견: DynamoDB `Decimal`이 응답에서 `"1.5"` **문자열로 직렬화** | 커스텀 JSON serializer로 숫자 복원 |
| 7 | 카나리/알람 기반 자동조치 | 개인 포폴은 평소 트래픽이 0 → 카나리 5분 동안 알람이 판단할 데이터가 없어 **나쁜 버전이 그대로 통과** | 카나리 동안 CI가 합성 트래픽(2rps×7분) 발생. 알람은 분당 20건 미만이면 0% 처리(오탐 방지) |
| 8 | 5xx 비율 알람 | 코드가 500을 "응답"으로 반환하면 Lambda `Errors` 메트릭엔 안 잡힘 | 장애는 처리되지 않은 예외로 → Lambda Errors + API 5XX 둘 다 상승 |

## 높음 — 예산 초과 · 보안

| # | 원본 설계 | 문제 | 수정 |
|---|---|---|---|
| 9 | 스로틀 초당 10건으로 "비용 폭주 방지" | 스로틀은 속도 제한일 뿐 **총량 제한이 아님.** 10rps × 30일 = 약 2,592만 건 ≈ **$90 (약 12만 원)** — 예산 6배 초과 가능. AWS Budgets도 없음 | ① API 키 + 사용량 계획 **월 50,000건 쿼터**(API 요금 상한 ≈ $0.2) ② Budgets 50%/예측 80% 메일 ③ 실제 100% 시 **킬스위치**(API 스로틀 0 + 배포 동결) |
| 10 | 메트릭 수집 | API Gateway **메서드별 상세 메트릭**을 켜면 유료 커스텀 메트릭으로 과금 | `metrics_enabled = false`, 스테이지 기본 메트릭(무료)만 사용 |
| 11 | 로그 14일 보존 | API Gateway **실행 로그**는 보존기간 무제한 로그 그룹을 자동 생성 → 14일 정책이 적용 안 됨 | 실행 로그 OFF, 액세스 로그(JSON, 14일) + Lambda 로그로 대체 |
| 12 | (누락) | API Gateway 로그에는 계정 단위 CloudWatch 역할 설정이 필요 — 없으면 stage 생성 실패 | `aws_api_gateway_account` + 전용 역할 |
| 13 | "최소권한, 와일드카드 지양" | Terraform 배포 역할은 IAM 역할을 만들 수 있어야 함 → **관리자 역할을 만들어 탈취하는 권한 상승 경로** | **권한 경계(Permissions Boundary)**: 배포 역할은 경계가 붙은 역할만 생성 가능, 워크로드 역할은 `/selfheal/` path에 격리 |
| 14 | OIDC 역할 1개 | PR(검토 전 코드)과 main 배포가 같은 권한 | `sub` 클레임으로 분리: main → 배포 역할, pull_request → **읽기 전용 plan 역할** |
| 15 | (누락) | 알림 이메일을 tfvars에 쓰면 공개 repo에 노출, PR plan 코멘트에도 노출 | GitHub Secret → `TF_VAR_alert_email`, 변수 `sensitive = true` |
| 16 | SNS 알림 | SNS 암호화를 켜면 CloudWatch 알람이 AWS 관리형 키 토픽에 **발행 불가**, CMK는 월 $1 | 미암호화 + 근거 명시(알람 메타데이터만 전송) |
| 17 | 자동 롤백 + CI/CD | 롤백 직후 다음 push가 **같은 결함을 재배포** | SSM `deploy-freeze` — 롤백/킬스위치 시 CI 배포 차단, 수동 `unfreeze` |
| 18 | 자동 롤백 | 카나리 도중 알람 시 CodeDeploy와 remediation이 **이중 롤백** 경합 | 배포 진행 중이면 remediation은 CodeDeploy에 위임 |
| 19 | (구현 재검토) | CodeDeploy가 먼저 롤백을 끝낸 뒤 알람 이벤트가 늦게 도착하면 "진행 중 배포 없음"으로 보여 **정상 버전을 한 번 더 되돌리는 연쇄 롤백** | 최근 20분 내 실패/중단 배포도 CodeDeploy 소관으로 위임 |
| 20 | (구현 재검토) | 5xx·Errors 알람이 동시에 울리면 두 번째 실행이 **틀린 "수동 조치 필요" 알림** | 동결 중 + live=stable이면 `already_frozen`으로 추가 조치 없이 알림 |

## 중간 — 설계 품질 · 정확성

| # | 원본 설계 | 문제 | 수정 |
|---|---|---|---|
| 21 | DynamoDB 쓰로틀 자동복구 | On-Demand는 쓰로틀이 거의 없어 **시연 불가** | 제거. Lambda 쓰로틀 알림으로 대체 |
| 22 | `terraform-lock` DynamoDB 테이블 | Terraform 1.10+ S3 네이티브 락으로 대체, DynamoDB 락은 deprecated | `use_lockfile = true` |
| 23 | S3 backend | state 버킷 자체를 만드는 단계 없음(닭과 달걀) | `bootstrap/` 스택(로컬 state, 1회) |
| 24 | 4xx/5xx 커스텀 메트릭 필터 | API Gateway 기본 메트릭에 이미 있음 | 기본 메트릭 + Metric Math `IF(requests>=20, 100*errors/requests, 0)` |
| 25 | 배포 시 보호 없음 | 배포 자체의 안전장치(점진 배포) 부재 | **CodeDeploy 카나리**(10% → 5분 → 100%) + 알람 자동 롤백 — 배포 시점(관리형)과 런타임(직접 구현) 2단 구조 |
| 26 | Python 런타임 | X-Ray/구조화 로그 라이브러리 패키징 미정 | Powertools 공식 레이어(버전 고정 — `latest` 추적 시 매 plan마다 드리프트) |
| 27 | `terraform-plan-comment` 액션 | 서드파티 액션에 PR 쓰기 권한 부여 | 공식 `actions/github-script` |
| 28 | "대부분 무료 티어" | 2025-07 프리티어 개편, API Gateway 등 12개월 무료는 기존 계정에서 만료 가능 | **유료 단가 기준 최악 비용**으로 재산정 (DESIGN.md §6) |

## 낮음 — 문서

| # | 문제 | 수정 |
|---|---|---|
| 29 | 6장 "Claude Pro 없이 진행" — 포트폴리오 내용이 아니고 현재 상황과도 다름 | 삭제, 실행 절차는 README 런북으로 |
| 30 | "5장 시간 추정치" 참조 — 5장은 비용표, 일정 없음 | 단계별 진행 순서/소요시간을 README에 명시 |
| 31 | 다이어그램에 CodeDeploy·쿼터·킬스위치·배포동결 없음 | 아키텍처 갱신 |

## 검증 결과

| 항목 | 결과 |
|---|---|
| `pytest` (API 8 · 자동복구 11 · 킬스위치 1) | 20 passed |
| `ruff check` / `ruff format --check` | 통과 |
| `terraform fmt -check` / `validate` (bootstrap, dev) | 통과 |
| `terraform plan` (실제 계정, 읽기 전용) | bootstrap 11개 · dev 59개 생성 계획, 오류 없음 |
| 실제 배포(`apply`) | **미실행** — 런북 참고 |
