"""handler.py 단위 테스트 (AWS/Mattermost 없이 실행).

    python -m unittest discover -s modules/rds-control/tests -v
"""

import base64
import json
import os
import sys
import types
import unittest
import urllib.parse
from unittest import mock

os.environ.update(
    DB_INSTANCE_ID="loompostgres",
    TARGET_ROLE_ARN="arn:aws:iam::111111111111:role/loom-rds-control",
    ALLOWED_CHANNEL_ID="chan-ok",
    TOKEN_PARAM="/loom/rds-control/mattermost-token",
    WEBHOOK_PARAM="/loom/rds-control/mattermost-webhook-url",
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))


class FakeRds:
    def __init__(self, statuses):
        self.statuses = list(statuses)  # describe 호출마다 하나씩 소비 (마지막 값 유지)
        self.calls = []

    def describe_db_instances(self, DBInstanceIdentifier):
        status = self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]
        return {"DBInstances": [{"DBInstanceStatus": status}]}

    def start_db_instance(self, DBInstanceIdentifier):
        self.calls.append(("start", DBInstanceIdentifier))

    def stop_db_instance(self, DBInstanceIdentifier):
        self.calls.append(("stop", DBInstanceIdentifier))


class FakeBoto3(types.ModuleType):
    def __init__(self, rds):
        super().__init__("boto3")
        self.rds = rds
        self.invocations = []

    def client(self, name, **kwargs):
        if name == "ssm":
            values = {
                "/loom/rds-control/mattermost-token": "secret-token",
                "/loom/rds-control/mattermost-webhook-url": "https://mm.example/hooks/x",
            }
            return types.SimpleNamespace(
                get_parameter=lambda Name, WithDecryption: {"Parameter": {"Value": values[Name]}}
            )
        if name == "sts":
            creds = {"AccessKeyId": "a", "SecretAccessKey": "b", "SessionToken": "c"}
            return types.SimpleNamespace(assume_role=lambda **kw: {"Credentials": creds})
        if name == "rds":
            return self.rds
        if name == "lambda":
            return types.SimpleNamespace(invoke=lambda **kw: self.invocations.append(kw))
        raise AssertionError(name)


class FakeContext:
    invoked_function_arn = "arn:aws:lambda:ap-northeast-2:222222222222:function:loom-rds-control"

    def __init__(self, remaining_ms=900_000):
        self.remaining_ms = remaining_ms

    def get_remaining_time_in_millis(self):
        return self.remaining_ms


def url_event(text, token="secret-token", channel="chan-ok", b64=False, method="POST"):
    body = urllib.parse.urlencode(
        {"token": token, "channel_id": channel, "user_name": "tester", "text": text}
    )
    if b64:
        body = base64.b64encode(body.encode()).decode()
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"content-type": "application/x-www-form-urlencoded"},
        "body": body,
        "isBase64Encoded": b64,
    }


class HandlerTest(unittest.TestCase):
    def setUp(self):
        import handler

        self.h = handler
        self.h._param_cache.clear()

    def run_with(self, statuses, event, context=None):
        fake = FakeBoto3(FakeRds(statuses))
        with mock.patch.dict(sys.modules, {"boto3": fake}):
            res = self.h.lambda_handler(event, context or FakeContext())
        return res, fake

    @staticmethod
    def body(res):
        return json.loads(res["body"])

    # --- 인증/권한 ---
    def test_rejects_wrong_token(self):
        res, _ = self.run_with(["available"], url_event("status", token="nope"))
        self.assertEqual(res["statusCode"], 401)

    def test_accepts_authorization_header_token(self):
        ev = url_event("status", token="")
        ev["headers"]["Authorization"] = "Token secret-token"
        res, _ = self.run_with(["available"], ev)
        self.assertIn("available", self.body(res)["text"])

    def test_rejects_other_channel(self):
        res, fake = self.run_with(["available"], url_event("start", channel="chan-x"))
        self.assertIn("이 채널", self.body(res)["text"])
        self.assertEqual(fake.rds.calls, [])

    def test_rejects_non_post(self):
        res, _ = self.run_with(["available"], url_event("status", method="GET"))
        self.assertEqual(res["statusCode"], 405)

    # --- 명령 ---
    def test_status_base64_body(self):
        res, _ = self.run_with(["stopped"], url_event("status", b64=True))
        self.assertEqual(self.body(res)["response_type"], "in_channel")
        self.assertIn("stopped", self.body(res)["text"])

    def test_help_when_empty(self):
        res, _ = self.run_with(["available"], url_event(""))
        self.assertIn("사용법", self.body(res)["text"])

    def test_start_when_stopped(self):
        res, fake = self.run_with(["stopped"], url_event("start"))
        self.assertEqual(fake.rds.calls, [("start", "loompostgres")])
        self.assertEqual(self.body(res)["response_type"], "in_channel")
        payload = json.loads(fake.invocations[0]["Payload"])
        self.assertEqual((payload["action"], payload["target"]), ("wait", "available"))
        self.assertEqual(fake.invocations[0]["InvocationType"], "Event")

    def test_start_when_already_running(self):
        res, fake = self.run_with(["available"], url_event("start"))
        self.assertEqual(fake.rds.calls, [])
        self.assertIn("시작할 수 없습니다", self.body(res)["text"])

    def test_stop_requires_confirm(self):
        res, fake = self.run_with(["available"], url_event("stop"))
        self.assertEqual(fake.rds.calls, [])
        self.assertIn("/rds stop confirm", self.body(res)["text"])

    def test_stop_confirm(self):
        res, fake = self.run_with(["available"], url_event("STOP Confirm"))
        self.assertEqual(fake.rds.calls, [("stop", "loompostgres")])
        self.assertEqual(json.loads(fake.invocations[0]["Payload"])["target"], "stopped")

    def test_unknown_command(self):
        res, _ = self.run_with(["available"], url_event("reboot"))
        self.assertIn("알 수 없는 명령", self.body(res)["text"])

    def test_aws_error_is_reported(self):
        fake = FakeBoto3(FakeRds(["available"]))
        fake.rds.describe_db_instances = mock.Mock(side_effect=RuntimeError("boom"))
        with mock.patch.dict(sys.modules, {"boto3": fake}):
            res = self.h.lambda_handler(url_event("status"), FakeContext())
        self.assertIn("RuntimeError", self.body(res)["text"])

    # --- 완료 대기 ---
    def test_wait_notifies_on_target(self):
        sent = []
        with mock.patch.object(self.h, "notify", sent.append), mock.patch.object(self.h.time, "sleep"):
            res, _ = self.run_with(
                ["starting", "starting", "available"],
                {"action": "wait", "target": "available", "user": "tester"},
            )
        self.assertEqual(res["status"], "available")
        self.assertEqual(len(sent), 1)
        self.assertIn("시작 완료", sent[0])

    def test_wait_timeout_notifies_in_progress(self):
        sent = []
        with mock.patch.object(self.h, "notify", sent.append), mock.patch.object(self.h.time, "sleep"):
            res, _ = self.run_with(
                ["starting"],
                {"action": "wait", "target": "available", "user": "tester"},
                FakeContext(remaining_ms=10_000),
            )
        self.assertTrue(res["timeout"])
        self.assertIn("아직", sent[0])


if __name__ == "__main__":
    unittest.main()
