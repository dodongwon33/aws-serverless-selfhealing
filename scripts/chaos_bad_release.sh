#!/usr/bin/env bash
# 장애 시연: "카나리를 우회한 잘못된 핫픽스"가 live에 올라간 상황을 재현하고 자가복구를 관찰한다.
#   ./scripts/chaos_bad_release.sh [FAULT_RATE=0.5]
# 예상 흐름(약 4~6분): 5xx 급증 → 알람(3분) → EventBridge → remediation → live가 stable로 복귀 → 메일 수신
set -euo pipefail

RATE="${1:-0.5}"
TF="terraform -chdir=infra/environments/dev"
FUNCTION=$($TF output -raw function_name)
API_URL=$($TF output -raw api_url)
API_KEY=$($TF output -raw api_key)

set_fault_rate() {
  local vars
  vars=$(aws lambda get-function-configuration --function-name "$FUNCTION" --query Environment.Variables --output json \
    | jq -c --arg r "$1" '.FAULT_RATE = $r')
  aws lambda update-function-configuration --function-name "$FUNCTION" --environment "{\"Variables\": $vars}" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION"
}

echo "== live 버전: v$(aws lambda get-alias --function-name "$FUNCTION" --name live --query FunctionVersion --output text)"

echo "== 1) FAULT_RATE=$RATE 인 장애 버전 발행"
set_fault_rate "$RATE"
BAD=$(aws lambda publish-version --function-name "$FUNCTION" --description "chaos FAULT_RATE=$RATE" --query Version --output text)

echo "== 2) \$LATEST 원복 (다음 정상 배포가 오염되지 않도록, Terraform 상태와도 일치)"
set_fault_rate "0"

echo "== 3) 장애 버전 v$BAD 를 live에 직접 반영 (카나리 우회)"
aws lambda update-alias --function-name "$FUNCTION" --name live --function-version "$BAD" \
  --routing-config '{"AdditionalVersionWeights": {}}' >/dev/null

echo "== 4) 트래픽 발생 — 30초마다 상태코드 분포와 live 버전 출력 (Ctrl+C로 중단 가능)"
python3 scripts/load.py --url "$API_URL" --key "$API_KEY" --rps 3 --duration 600 --watch-function "$FUNCTION"

echo "== 완료. 배포 동결이 걸려 있으니 확인 후 deploy 워크플로를 unfreeze=true로 실행하세요."
