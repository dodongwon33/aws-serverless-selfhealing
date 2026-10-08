import json
from types import SimpleNamespace

import boto3
import pytest
from moto import mock_aws

import app as app_module


def ctx():
    return SimpleNamespace(
        function_name="selfheal-test-api",
        memory_limit_in_mb=256,
        invoked_function_arn="arn:aws:lambda:ap-northeast-2:123456789012:function:selfheal-test-api:live",
        aws_request_id="req-1",
    )


def event(method, path, resource, body=None, path_params=None):
    return {
        "resource": resource,
        "path": path,
        "httpMethod": method,
        "headers": {"Content-Type": "application/json"},
        "multiValueHeaders": {},
        "queryStringParameters": None,
        "multiValueQueryStringParameters": None,
        "pathParameters": path_params,
        "stageVariables": None,
        "requestContext": {"requestId": "req-1", "stage": "v1", "resourcePath": resource, "httpMethod": method},
        "body": body,
        "isBase64Encoded": False,
    }


@pytest.fixture(autouse=True)
def dynamodb(monkeypatch):
    monkeypatch.setenv("FAULT_RATE", "0")
    monkeypatch.setenv("FAULT_LATENCY_MS", "0")
    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName="selfheal-test-items",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        app_module._table = None
        yield
        app_module._table = None


def test_health():
    resp = app_module.lambda_handler(event("GET", "/health", "/health"), ctx())
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["status"] == "ok"


def test_create_then_get_roundtrip_with_float():
    body = json.dumps({"payload": {"name": "a", "price": 1.5}})
    created = app_module.lambda_handler(event("POST", "/items", "/items", body), ctx())
    assert created["statusCode"] == 201
    item_id = json.loads(created["body"])["id"]

    got = app_module.lambda_handler(
        event("GET", f"/items/{item_id}", "/items/{id}", path_params={"id": item_id}), ctx()
    )
    assert got["statusCode"] == 200
    assert json.loads(got["body"])["payload"] == {"name": "a", "price": 1.5}


def test_get_missing_item_is_404():
    resp = app_module.lambda_handler(event("GET", "/items/nope", "/items/{id}", path_params={"id": "nope"}), ctx())
    assert resp["statusCode"] == 404


@pytest.mark.parametrize("body", ["not-json", json.dumps({"payload": "str"}), json.dumps([1])])
def test_invalid_body_is_400(body):
    resp = app_module.lambda_handler(event("POST", "/items", "/items", body), ctx())
    assert resp["statusCode"] == 400


def test_oversized_body_is_400():
    body = json.dumps({"payload": {"x": "a" * 11000}})
    resp = app_module.lambda_handler(event("POST", "/items", "/items", body), ctx())
    assert resp["statusCode"] == 400


def test_fault_injection_raises(monkeypatch):
    monkeypatch.setenv("FAULT_RATE", "1")
    with pytest.raises(RuntimeError, match="injected fault"):
        app_module.lambda_handler(event("GET", "/health", "/health"), ctx())
