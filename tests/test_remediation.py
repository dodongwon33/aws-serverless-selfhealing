import pytest

from remediation import NONE, Remediator, decide_target

CFG = {
    "FUNCTION_NAME": "selfheal-dev-api",
    "ALIAS_NAME": "live",
    "STABLE_PARAM": "/selfheal/dev/stable-version",
    "PREVIOUS_PARAM": "/selfheal/dev/previous-version",
    "FREEZE_PARAM": "/selfheal/dev/deploy-freeze",
    "ALERTS_TOPIC_ARN": "arn:aws:sns:ap-northeast-2:123456789012:selfheal-dev-alerts",
    "CODEDEPLOY_APP": "selfheal-dev",
    "CODEDEPLOY_GROUP": "selfheal-dev-api",
}


class FakeLambda:
    def __init__(self, live):
        self.live = live
        self.updates = []

    def get_alias(self, FunctionName, Name):
        return {"FunctionVersion": self.live}

    def update_alias(self, **kw):
        self.updates.append(kw)
        self.live = kw["FunctionVersion"]


class FakeSsm:
    def __init__(self, stable, previous):
        self.params = {CFG["STABLE_PARAM"]: stable, CFG["PREVIOUS_PARAM"]: previous, CFG["FREEZE_PARAM"]: "false"}

    def get_parameter(self, Name):
        return {"Parameter": {"Value": self.params[Name]}}

    def put_parameter(self, Name, Value, Overwrite):
        assert Overwrite
        self.params[Name] = Value


class FakeSns:
    def __init__(self):
        self.messages = []

    def publish(self, **kw):
        self.messages.append(kw)


class FakeCodeDeploy:
    def __init__(self, active=()):
        self.active = list(active)
        self.calls = []

    def list_deployments(self, **kw):
        self.calls.append(kw)
        return {"deployments": self.active}


def alarm_event(state="ALARM"):
    return {"detail": {"alarmName": "selfheal-dev-api-5xx-rate", "state": {"value": state}}}


def make(live, stable, previous, active=(), frozen=False):
    lam, ssm, sns = FakeLambda(live), FakeSsm(stable, previous), FakeSns()
    if frozen:
        ssm.params[CFG["FREEZE_PARAM"]] = "true"
    return Remediator(CFG, lam, ssm, sns, FakeCodeDeploy(active)), lam, ssm, sns


@pytest.mark.parametrize(
    "live,stable,previous,expected",
    [
        ("7", "5", "4", "5"),  # 카나리 우회 배포 → stable로
        ("5", "5", "4", "4"),  # stable 자체가 나빠짐 → previous로
        ("5", "5", NONE, None),  # 되돌아갈 곳 없음
        ("5", "5", "5", None),
    ],
)
def test_decide_target(live, stable, previous, expected):
    assert decide_target(live, stable, previous) == expected


def test_rollback_bypassed_release_to_stable():
    r, lam, ssm, sns = make(live="7", stable="5", previous="4")
    result = r.run(alarm_event())
    assert result == {"action": "rolled_back", "alarm": "selfheal-dev-api-5xx-rate", "from": "7", "to": "5"}
    assert lam.updates[0]["RoutingConfig"] == {"AdditionalVersionWeights": {}}
    assert ssm.params == {CFG["STABLE_PARAM"]: "5", CFG["PREVIOUS_PARAM"]: NONE, CFG["FREEZE_PARAM"]: "true"}
    assert len(sns.messages) == 1


def test_rollback_bad_stable_to_previous_then_no_flapping():
    r, lam, ssm, _ = make(live="5", stable="5", previous="4")
    assert r.run(alarm_event())["to"] == "4"
    # 두 번째 알람(동시 발생한 다른 알람 포함)은 추가 롤백 없이 동결 상태만 알린다
    assert r.run(alarm_event())["action"] == "already_frozen"
    assert lam.live == "4" and len(lam.updates) == 1


def test_manual_required_freezes_deploys():
    r, lam, ssm, sns = make(live="5", stable="5", previous=NONE)
    assert r.run(alarm_event())["action"] == "manual_required"
    assert lam.updates == []
    assert ssm.params[CFG["FREEZE_PARAM"]] == "true"
    assert len(sns.messages) == 1


def test_ok_state_is_ignored():
    r, lam, _, sns = make(live="7", stable="5", previous="4")
    assert r.run(alarm_event("OK"))["action"] == "ignored"
    assert lam.updates == [] and sns.messages == []


def test_delegates_to_codedeploy_during_canary():
    r, lam, ssm, sns = make(live="7", stable="5", previous="4", active=["d-123"])
    assert r.run(alarm_event())["action"] == "delegated_to_codedeploy"
    assert lam.updates == []
    assert ssm.params[CFG["FREEZE_PARAM"]] == "false"


def test_frozen_but_live_differs_still_rolls_back():
    # 동결 중이라도 누군가 live를 직접 바꿔 장애가 나면 stable로 복구한다
    r, lam, _, _ = make(live="9", stable="5", previous=NONE, frozen=True)
    assert r.run(alarm_event())["to"] == "5"


def test_delegation_window_covers_recently_failed_canary():
    r, _, _, _ = make(live="5", stable="5", previous="4")
    r.run(alarm_event())
    call = r.cd.calls[0]
    assert {"Failed", "Stopped", "InProgress"} <= set(call["includeOnlyStatuses"])
    span = call["createTimeRange"]["end"] - call["createTimeRange"]["start"]
    assert span.total_seconds() == 20 * 60
