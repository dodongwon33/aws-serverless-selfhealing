from killswitch import run


class Recorder:
    def __init__(self):
        self.calls = []

    def __getattr__(self, name):
        return lambda **kw: self.calls.append((name, kw))


def test_killswitch_blocks_api_and_freezes():
    cfg = {
        "REST_API_ID": "abc123",
        "STAGE_NAME": "v1",
        "FREEZE_PARAM": "/selfheal/dev/deploy-freeze",
        "ALERTS_TOPIC_ARN": "arn:aws:sns:ap-northeast-2:123456789012:selfheal-dev-alerts",
    }
    apigw, ssm, sns = Recorder(), Recorder(), Recorder()
    assert run(cfg, apigw, ssm, sns)["action"] == "api_blocked"

    ((name, kw),) = apigw.calls
    assert name == "update_stage" and kw["restApiId"] == "abc123"
    assert {op["value"] for op in kw["patchOperations"]} == {"0"}
    assert ssm.calls == [("put_parameter", {"Name": cfg["FREEZE_PARAM"], "Value": "true", "Overwrite": True})]
    assert sns.calls[0][0] == "publish"
