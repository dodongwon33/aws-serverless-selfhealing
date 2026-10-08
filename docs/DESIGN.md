# AWS 서버리스 관측성 & 자가복구 시스템 — 설계서 (v2)

> v1 초안의 결함 31건을 반영한 개정판. 변경 근거는 [REVIEW.md](REVIEW.md).

## 0. 개요

| 항목 | 내용 |
|---|---|
| 목적 | 클라우드/네트워크 직무 포트폴리오 |
| 핵심 | 서버리스 API + 관측성(로그·메트릭·트레이스) + **2단 자동 롤백**(배포 시점 카나리 / 런타임 알람) + CI/CD + **비용 상한 설계** |
| 예산 | 월 1~2만 원 이하. 이 프로젝트 증가분 최악 **약 $0.6(약 900원)**, 계정 전체 Budgets 한도 $10 |
| 리전 | ap-northeast-2 (서울) |
| IaC / CI | Terraform 1.10+ (AWS provider 6.x) / GitHub Actions + OIDC |

## 1. 아키텍처

```
                 GitHub (PR)                         GitHub (main push)
                     │ OIDC: plan 역할(읽기전용)            │ OIDC: deploy 역할(권한경계)
                     ▼                                   ▼
           lint · test · fmt · validate         freeze 확인 → terraform apply
           terraform plan → PR 코멘트            → publish-version → CodeDeploy 카나리
                                                  (10% 5분, 합성 트래픽) → 스모크 → stable 승격
                                                         │
 Client ──x-api-key──▶ API Gateway (REST, v1) ──▶ Lambda alias `live` ──▶ DynamoDB (온디맨드, PITR)
                       쿼터 5만/월 · 5rps            Powertools 로그/트레이스
                       액세스로그 · X-Ray                    │
                                │                            │
                                ▼                            ▼
                    CloudWatch 메트릭 · Logs(14일) · X-Ray · 대시보드 · Logs Insights 쿼리
                                │
                    ┌───────────┴─────────────────────────────┐
              5xx율>5% (3분) / Lambda Errors≥3 (2분)        p99>3s, Throttles
                    │                                        │
          ┌─────────┼───────────────┐                        ▼
          ▼         ▼               ▼                      SNS → 메일
     CodeDeploy  EventBridge      SNS → 메일
     (카나리 중   → remediation Lambda
      자동 롤백)   → alias를 stable/previous로 → deploy-freeze=true → 메일

 AWS Budgets ($10/월, 계정 전체) ─ 50%·예측80% → 메일
                                 └ 실제100% → SNS → killswitch Lambda → API 스로틀 0 + deploy-freeze
```

## 2. 컴포넌트

### 2.1 API Gateway (REST)
- **REST를 고른 이유**: X-Ray 트레이싱과 사용량 계획(쿼터)이 REST 전용. HTTP API 대비 요금 차이는 쿼터 상한 기준 월 $0.1 미만.
- 엔드포인트: `GET /health`, `POST /items`, `GET /items/{id}` — 모두 `x-api-key` 필요.
- 비용 방어: 스테이지 스로틀 5rps/버스트 10 + 사용량 계획 **월 50,000건** 쿼터.
- 통합 대상: Lambda **alias `live`** (`$LATEST` 아님).
- 로그: 액세스 로그(JSON: status, latency, integrationError, xrayTraceId) 14일. 실행 로그·메서드 상세 메트릭은 비용 이유로 OFF.

### 2.2 Lambda
| 함수 | 역할 | 소유 |
|---|---|---|
| `selfheal-dev-api` | 비즈니스 로직, 장애 주입(`FAULT_RATE`, `FAULT_LATENCY_MS`) | 설정=Terraform, 코드/버전=CI |
| `selfheal-dev-remediation` | 알람 → alias 롤백 | Terraform |
| `selfheal-dev-killswitch` | 예산 초과 → API 차단 | Terraform |

- Python 3.12, 256MB(API)/128MB(보조), Powertools 레이어(버전 고정), X-Ray Active.
- 요청 본문 10KB 제한, 처리되지 않은 예외는 그대로 전파(→ Errors 메트릭).

### 2.3 DynamoDB
- `selfheal-dev-items` (PK `id`), On-Demand, PITR on, AWS 소유 키 암호화(무료).
- 스키마: `id`(S) · `createdAt`(ISO8601) · `status`(active) · `payload`(Map).

### 2.4 관측성
| 축 | 구현 |
|---|---|
| 로그 | Powertools 구조화 JSON(correlation_id = API requestId), API 액세스 로그, 보존 14일 |
| 메트릭 | AWS 기본 메트릭만(커스텀 0개). 대시보드 1개: 알람 상태, 요청/4xx/5xx, p50/p99, Lambda 호출/에러/쓰로틀, DynamoDB |
| 트레이스 | API Gateway + Lambda Active tracing, Powertools Tracer가 boto3(DynamoDB) 서브세그먼트 기록 |
| 분석 | Logs Insights 저장 쿼리: 버전별 에러, 느린/실패 요청 |

### 2.5 알람 (메트릭 5개 — 무료 10개 이내)
| 알람 | 조건 | 조치 |
|---|---|---|
| `api-5xx-rate` | `IF(Count≥20, 100·5XX/Count, 0) > 5` 3분 연속 | CodeDeploy 롤백 / remediation / 메일 |
| `lambda-errors` | alias Errors ≥ 3/분, 2분 연속 | 동일 |
| `api-latency-p99` | p99 > 3초, 3분 연속 | 메일만 (원인 다양) |
| `lambda-throttles` | Throttles > 0 | 메일만 |

### 2.6 2단 자동 롤백
**배포 시점 (관리형)** — CodeDeploy `LambdaCanary10Percent5Minutes`. 알람 발생 시 `DEPLOYMENT_STOP_ON_ALARM`으로 자동 롤백. 저트래픽 보완을 위해 CI가 카나리 동안 합성 트래픽 발생.

**런타임 (직접 구현)** — 알람 상태 변경 이벤트 → EventBridge → remediation:
1. 상태가 ALARM이 아니면 무시
2. CodeDeploy 배포가 진행 중이거나 최근 20분 내 실패/중단됐으면 위임(이중·연쇄 롤백 방지)
3. 이미 동결 중이고 live=stable이면 추가 조치 없이 알림(동시 알람 중복 처리)
4. 대상 결정: `live≠stable → stable` / `live=stable → previous` / 그 외 수동 조치 알림
5. alias 갱신(가중치 제거) → `stable=대상`, `previous=none`(플래핑 방지) → `deploy-freeze=true` → 메일

| 상황 | 예 | 처리 |
|---|---|---|
| 카나리 우회 핫픽스가 장애 | live=7, stable=5 | 5로 롤백 |
| 검증 통과 버전이 운영 중 장애 | live=stable=5, previous=4 | 4로 롤백 |
| 되돌아갈 곳 없음 | 최초 배포 | 롤백 없이 동결 + 수동 조치 메일 |

### 2.7 SSM Parameter Store (표준, 무료)
`/selfheal/dev/stable-version`, `/previous-version`, `/deploy-freeze` — Terraform은 생성만, 값은 CI/remediation이 소유(`ignore_changes`).

## 3. Terraform 구조

```
bootstrap/                  # 1회, 로컬 state: state 버킷 · OIDC · deploy/plan 역할 · 권한 경계
infra/
├── environments/dev/       # S3 backend(use_lockfile) · 모듈 조립
└── modules/
    ├── lambda_app/         # API 함수 + alias (코드/버전은 ignore_changes)
    ├── lambda_function/    # 보조 함수 공통 모듈
    ├── dynamodb/  api/  notification/  monitoring/
    ├── deploy/             # CodeDeploy 앱/그룹
    ├── remediation/        # SSM 파라미터 · EventBridge · 롤백 함수
    └── guardrails/         # Budgets · 킬스위치
```
- **코드 소유권 분리**: Terraform이 Lambda 코드와 alias 버전을 관리하면 CI 배포 때마다 둘이 충돌 → Terraform은 설정만, CI가 코드·버전.

## 4. CI/CD

| 워크플로 | 트리거 | 단계 |
|---|---|---|
| `ci.yml` | PR | ruff · pytest · fmt · validate → (plan 역할) plan → PR 코멘트 |
| `deploy.yml` | main push / 수동 | 테스트 → **freeze 확인** → apply → 버전 발행 → 카나리(+합성 트래픽) → 스모크(health + 쓰기/읽기) → stable 승격 |

AWS 연결 전에는 `vars.AWS_*`가 비어 있어 배포 job이 자동으로 건너뛰어진다(테스트는 항상 실행).

## 5. 보안
- **장기 Access Key 0개**: GitHub OIDC. `sub` 클레임으로 main(배포)·PR(읽기전용 plan) 역할 분리.
- **권한 경계**: 배포 역할은 `selfheal-workload-boundary`가 붙은 역할만 `/selfheal/` path에 생성 가능 → 권한 상승 차단. bootstrap 역할(path `/`)은 수정 불가.
- 리소스 ARN을 `selfheal-*`로 스코프(API Gateway만 ID 기반이라 리전 스코프).
- state 버킷: 버전관리, SSE-S3, 퍼블릭 차단, TLS 강제. API 키·이메일은 sensitive.

## 6. 비용 (서울 리전, 무료 티어가 전부 만료됐다고 가정한 최악)

쿼터 50,000건/월을 전부 소진하는 경우(평소엔 배포·시연 트래픽 수천 건):

| 항목 | 산정 | 월 |
|---|---|---|
| API Gateway REST | 5만 × ~$4/백만 | $0.20 |
| Lambda | 5만 × (요청 $0.2/백만 + 0.25GB×0.2s) | $0.05 |
| DynamoDB On-Demand | 쓰기 1만 + 읽기 소량, 저장 수 MB | $0.02 |
| CloudWatch Logs | 수집 ~0.1GB × $0.76 | $0.08 |
| X-Ray | 기본 샘플링(1rps+5%), 최대 5만 트레이스 × $5/백만 | $0.25 |
| 알람 5 · 대시보드 1 · 저장쿼리 | 상시 무료 한도(알람 10 · 대시보드 3) 내 | $0 |
| S3 state · SSM 표준 · EventBridge(AWS 이벤트) · SNS 메일 · CodeDeploy(Lambda) · Budgets(액션 미사용) | 무료/극소 | ~$0.01 |
| **합계(최악)** | | **≈ $0.6 (약 900원)** |

**예산 방어 (AWS엔 하드 상한이 없으므로 다층)**: ① 쿼터 = 요청 수 상한 ② Budgets $10(계정 전체; 기존 리소스 지출 포함) 50%·예측 80% 메일 ③ 실제 100% → 킬스위치.
**금지 목록**: NAT Gateway, VPC 내 Lambda, RDS/EKS/Fargate 상시, 고객 관리형 KMS 키, Secrets Manager, CloudWatch Synthetics, Lambda Insights, 메서드 상세 메트릭, 무제한 로그 보존, X-Ray 100% 샘플링.

## 7. 알려진 한계 · 다음 단계
- Budgets 데이터는 최대 수 시간 지연 → 킬스위치는 "마지막 안전망". 실질 상한은 쿼터.
- `aws_api_gateway_account`는 리전 단위 계정 공유 설정(같은 계정의 다른 API에도 적용).
- 단일 dev 환경. prod 분리 시 계정 분리(Organizations) 권장.
- 다음: CodeDeploy `BeforeAllowTraffic` 훅으로 새 버전 사전 검증, Trivy/checkov IaC 스캔, Slack 알림.
