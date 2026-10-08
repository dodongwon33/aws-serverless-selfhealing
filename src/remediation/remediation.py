"""자동복구: CloudWatch 알람(ALARM) → EventBridge → Lambda alias 롤백.

버전 bookkeeping (SSM Parameter Store, 표준 파라미터 = 무료)
  stable-version   : 마지막으로 카나리 + 스모크 테스트를 통과한 버전
  previous-version : 그 직전 stable (없으면 "none")
  deploy-freeze    : "true"면 CI 배포 차단 (롤백 직후 같은 버전 재배포 방지)

롤백 대상
  live != stable  → stable  (카나리를 우회한 배포/핫픽스가 live에 올라간 경우)
  live == stable  → previous (검증을 통과했지만 운영 중 문제가 드러난 경우)
  그 외           → 자동 조치 불가, 사람에게 알림
"""

import json
import logging
import os
from datetime import UTC, datetime, timedelta

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

NONE = "none"
# 진행 중 + 최근 실패/중단: CodeDeploy가 먼저 롤백을 끝낸 뒤 이 이벤트가 늦게 도착하면
# "진행 중 배포 없음"으로 보여 정상 버전을 한 번 더 되돌리는 연쇄 롤백이 생긴다.
DELEGATE_STATUSES = ["Created", "Queued", "InProgress", "Ready", "Failed", "Stopped"]
DELEGATE_WINDOW = timedelta(minutes=20)  # 카나리 5분 + 알람 평가 3분 + 여유


def decide_target(live, stable, previous):
    if live != stable:
        return stable
    if previous and previous not in (NONE, live):
        return previous
    return None


class Remediator:
    def __init__(self, cfg, lambda_client, ssm_client, sns_client, codedeploy_client):
        self.cfg = cfg
        self.lam = lambda_client
        self.ssm = ssm_client
        self.sns = sns_client
        self.cd = codedeploy_client

    def _param(self, name):
        return self.ssm.get_parameter(Name=name)["Parameter"]["Value"]

    def _put(self, name, value):
        self.ssm.put_parameter(Name=name, Value=value, Overwrite=True)

    def _notify(self, subject, body):
        self.sns.publish(
            TopicArn=self.cfg["ALERTS_TOPIC_ARN"],
            Subject=subject[:100],
            Message=json.dumps(body, ensure_ascii=False, indent=2),
        )

    def _codedeploy_owns_incident(self, now):
        resp = self.cd.list_deployments(
            applicationName=self.cfg["CODEDEPLOY_APP"],
            deploymentGroupName=self.cfg["CODEDEPLOY_GROUP"],
            includeOnlyStatuses=DELEGATE_STATUSES,
            createTimeRange={"start": now - DELEGATE_WINDOW, "end": now},
        )
        return bool(resp.get("deployments"))

    def run(self, event, now=None):
        now = now or datetime.now(UTC)
        detail = event.get("detail", {})
        alarm = detail.get("alarmName", "unknown")
        if detail.get("state", {}).get("value") != "ALARM":
            return {"action": "ignored", "alarm": alarm}

        if self._codedeploy_owns_incident(now):
            # 카나리 배포 중에는 CodeDeploy가 같은 알람으로 자동 롤백한다. 이중 조치 방지.
            result = {"action": "delegated_to_codedeploy", "alarm": alarm}
            self._notify(f"[selfheal] {alarm}: CodeDeploy 롤백에 위임", result)
            return result

        fn, alias = self.cfg["FUNCTION_NAME"], self.cfg["ALIAS_NAME"]
        live = self.lam.get_alias(FunctionName=fn, Name=alias)["FunctionVersion"]
        stable = self._param(self.cfg["STABLE_PARAM"])
        previous = self._param(self.cfg["PREVIOUS_PARAM"])
        frozen = self._param(self.cfg["FREEZE_PARAM"]) == "true"

        if frozen and live == stable:
            # 이미 롤백(또는 킬스위치)으로 동결된 상태. 두 알람이 동시에 울린 중복 이벤트이거나
            # 롤백한 버전도 문제인 경우 — 어느 쪽이든 자동으로 더 되돌리지 않는다.
            result = {"action": "already_frozen", "alarm": alarm, "live": live}
            self._notify(f"[selfheal] {alarm}: 동결 중 — 이미 조치됨, 알람 지속 시 수동 확인", result)
            return result

        target = decide_target(live, stable, previous)

        if target is None:
            self._put(self.cfg["FREEZE_PARAM"], "true")
            result = {"action": "manual_required", "alarm": alarm, "live": live, "stable": stable, "previous": previous}
            self._notify(f"[selfheal] {alarm}: 롤백 대상 없음 — 수동 조치 필요", result)
            return result

        self.lam.update_alias(
            FunctionName=fn,
            Name=alias,
            FunctionVersion=target,
            RoutingConfig={"AdditionalVersionWeights": {}},
        )
        # 롤백된 버전이 새 기준점. 같은 알람이 다시 울려도 나쁜 버전으로 되돌아가지 않게 previous를 비운다.
        self._put(self.cfg["STABLE_PARAM"], target)
        self._put(self.cfg["PREVIOUS_PARAM"], NONE)
        self._put(self.cfg["FREEZE_PARAM"], "true")

        result = {"action": "rolled_back", "alarm": alarm, "from": live, "to": target}
        logger.info(json.dumps(result))
        self._notify(f"[selfheal] {alarm}: v{live} → v{target} 자동 롤백", result)
        return result


def handler(event, context):
    remediator = Remediator(
        os.environ,
        boto3.client("lambda"),
        boto3.client("ssm"),
        boto3.client("sns"),
        boto3.client("codedeploy"),
    )
    return remediator.run(event)
