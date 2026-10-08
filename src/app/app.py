"""비즈니스 API Lambda (API Gateway REST → Lambda alias `live` → DynamoDB).

장애 주입: 환경변수 FAULT_RATE / FAULT_LATENCY_MS.
Lambda 버전은 환경변수까지 스냅샷하므로, 장애가 주입된 버전을 alias에서
이전 버전으로 되돌리면 장애도 함께 사라진다(= 자가복구 시연이 성립하는 이유).
"""

import json
import os
import random
import time
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
from aws_lambda_powertools.event_handler.exceptions import BadRequestError, NotFoundError
from aws_lambda_powertools.logging import correlation_paths

MAX_BODY_BYTES = 10 * 1024


def _json_default(obj):
    # DynamoDB는 숫자를 Decimal로 돌려준다. 기본 직렬화는 문자열("1.5")로 바꿔버리므로 숫자로 복원한다.
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    raise TypeError(f"{type(obj).__name__} is not JSON serializable")


logger = Logger()
tracer = Tracer()
app = APIGatewayRestResolver(serializer=lambda body: json.dumps(body, default=_json_default, separators=(",", ":")))

_table = None


def table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def inject_faults():
    latency_ms = int(os.environ.get("FAULT_LATENCY_MS", "0"))
    if latency_ms > 0:
        time.sleep(latency_ms / 1000)
    rate = float(os.environ.get("FAULT_RATE", "0"))
    if rate > 0 and random.random() < rate:
        # 처리되지 않은 예외 → Lambda Errors 메트릭 + API Gateway 502(5XX)
        raise RuntimeError(f"injected fault (FAULT_RATE={rate})")


@app.get("/health")
def health():
    return {"status": "ok", "version": os.environ.get("AWS_LAMBDA_FUNCTION_VERSION", "local")}


@app.post("/items")
@tracer.capture_method
def create_item():
    raw = app.current_event.body or ""
    if len(raw.encode()) > MAX_BODY_BYTES:
        raise BadRequestError(f"body must be <= {MAX_BODY_BYTES} bytes")
    try:
        body = json.loads(raw or "{}", parse_float=Decimal)
    except json.JSONDecodeError as exc:
        raise BadRequestError("body must be valid JSON") from exc
    payload = body.get("payload") if isinstance(body, dict) else None
    if not isinstance(payload, dict):
        raise BadRequestError("'payload' must be a JSON object")

    item = {
        "id": str(uuid.uuid4()),
        "createdAt": datetime.now(UTC).isoformat(),
        "status": "active",
        "payload": payload,
    }
    table().put_item(Item=item)
    logger.info("item created", extra={"item_id": item["id"]})
    return item, 201


@app.get("/items/<item_id>")
@tracer.capture_method
def get_item(item_id: str):
    item = table().get_item(Key={"id": item_id}).get("Item")
    if item is None:
        raise NotFoundError(f"item {item_id} not found")
    return item


@logger.inject_lambda_context(correlation_id_path=correlation_paths.API_GATEWAY_REST)
@tracer.capture_lambda_handler
def lambda_handler(event, context):
    inject_faults()
    return app.resolve(event, context)
