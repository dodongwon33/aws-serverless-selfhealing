"""예산 킬스위치: AWS Budgets(실제 비용 100%) → SNS → API 스테이지 스로틀 0.

AWS에는 하드 지출 상한이 없으므로, 예산을 넘기면 트래픽 유입 자체를 막는다.
deploy-freeze도 함께 걸어 CI의 terraform apply가 스로틀을 조용히 되돌리지 못하게 한다.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def run(cfg, apigw, ssm, sns):
    apigw.update_stage(
        restApiId=cfg["REST_API_ID"],
        stageName=cfg["STAGE_NAME"],
        patchOperations=[
            {"op": "replace", "path": "/*/*/throttling/rateLimit", "value": "0"},
            {"op": "replace", "path": "/*/*/throttling/burstLimit", "value": "0"},
        ],
    )
    ssm.put_parameter(Name=cfg["FREEZE_PARAM"], Value="true", Overwrite=True)
    result = {"action": "api_blocked", "restApiId": cfg["REST_API_ID"], "stage": cfg["STAGE_NAME"]}
    sns.publish(
        TopicArn=cfg["ALERTS_TOPIC_ARN"],
        Subject="[selfheal] 예산 초과 — API 차단 (킬스위치)",
        Message=json.dumps(result, ensure_ascii=False, indent=2),
    )
    logger.info(json.dumps(result))
    return result


def handler(event, context):
    return run(os.environ, boto3.client("apigateway"), boto3.client("ssm"), boto3.client("sns"))
