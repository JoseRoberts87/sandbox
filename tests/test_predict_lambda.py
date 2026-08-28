"""API Gateway -> SageMaker proxy.

boto3 is stubbed, so these run with no AWS and no network. The behaviour under
test is what the proxy does with a request and with each failure mode the
endpoint can return — including what it declines to tell an external caller.
"""

import base64
import importlib.util
import json
import sys
import types
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = "sandbox-dev-refund-risk"


ORDER = {
    "region": "emea", "channel": "retail", "category": "puzzles",
    "quantity": 2, "unit_price_usd": 30.0, "discount_pct": 0.0,
    "shipping_days": 4, "order_dow": 3,
}


class FakeClientError(Exception):
    """Stands in for botocore.exceptions.ClientError."""

    def __init__(self, code, message="something went wrong"):
        super().__init__(f"{code}: {message}")
        self.response = {"Error": {"Code": code, "Message": message}}


class FakeRuntime:
    """Records the last call, and returns whatever the test asked for."""

    def __init__(self):
        self.body = {"predictions": [{"refund_probability": 0.42}]}
        self.raise_error = None
        self.last_call = None

    def invoke_endpoint(self, **kwargs):
        self.last_call = kwargs
        if self.raise_error:
            raise self.raise_error
        payload = json.dumps(self.body).encode()
        return {"Body": types.SimpleNamespace(read=lambda: payload)}


@pytest.fixture
def proxy(monkeypatch):
    runtime = FakeRuntime()

    boto3_stub = types.ModuleType("boto3")
    boto3_stub.client = lambda *args, **kwargs: runtime

    exceptions_stub = types.ModuleType("botocore.exceptions")
    exceptions_stub.ClientError = FakeClientError
    botocore_stub = types.ModuleType("botocore")
    botocore_stub.exceptions = exceptions_stub

    monkeypatch.setitem(sys.modules, "boto3", boto3_stub)
    monkeypatch.setitem(sys.modules, "botocore", botocore_stub)
    monkeypatch.setitem(sys.modules, "botocore.exceptions", exceptions_stub)
    monkeypatch.setenv("ENDPOINT_NAME", ENDPOINT)
    monkeypatch.setenv("MAX_INSTANCES", "3")
    monkeypatch.setenv("REQUIRED_FIELDS", ",".join(ORDER))

    spec = importlib.util.spec_from_file_location(
        "predict_handler", ROOT / "lambda" / "predict" / "handler.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, runtime


def call(proxy, body, **event):
    module, runtime = proxy
    if not isinstance(body, str):
        body = json.dumps(body)
    response = module.handler({"body": body, **event}, None)
    return response, json.loads(response["body"]), runtime


class TestSuccess:
    def test_valid_request_returns_predictions(self, proxy):
        response, body, _ = call(proxy, {"instances": [ORDER]})
        assert response["statusCode"] == 200
        assert body["predictions"][0]["refund_probability"] == 0.42

    def test_forwards_to_the_configured_endpoint_as_json(self, proxy):
        _, _, runtime = call(proxy, {"instances": [ORDER]})
        assert runtime.last_call["EndpointName"] == ENDPOINT
        assert runtime.last_call["ContentType"] == "application/json"
        assert json.loads(runtime.last_call["Body"]) == {"instances": [ORDER]}

    def test_normalises_a_bare_list(self, proxy):
        _, _, runtime = call(proxy, [ORDER])
        assert json.loads(runtime.last_call["Body"]) == {"instances": [ORDER]}

    def test_normalises_a_single_object(self, proxy):
        _, _, runtime = call(proxy, ORDER)
        assert json.loads(runtime.last_call["Body"]) == {"instances": [ORDER]}

    def test_decodes_a_base64_body(self, proxy):
        # API Gateway base64-encodes bodies depending on content handling.
        encoded = base64.b64encode(json.dumps({"instances": [ORDER]}).encode()).decode()
        response, body, _ = call(proxy, encoded, isBase64Encoded=True)
        assert response["statusCode"] == 200

    def test_always_declares_json(self, proxy):
        response, _, _ = call(proxy, {"instances": [ORDER]})
        assert response["headers"]["Content-Type"] == "application/json"


class TestBadRequests:
    @pytest.mark.parametrize(
        "body,fragment",
        [
            ("", "empty"),
            ("{not json", "not valid JSON"),
            ('{"instances": []}', "no instances"),
            ('{"instances": [1]}', "must be a JSON object"),
            ('"a string"', "expected a JSON object or array"),
        ],
    )
    def test_malformed_input_is_rejected_before_invoking(self, proxy, body, fragment):
        response, parsed, runtime = call(proxy, body)
        assert response["statusCode"] == 400
        assert fragment in parsed["error"]
        # The endpoint must not be woken for a request that cannot be valid.
        assert runtime.last_call is None

    def test_missing_required_field_is_caught_before_the_model(self, proxy):
        """Regression: this used to reach the endpoint, which returned an HTML
        500 that SageMaker wrapped in a message containing the AWS account id
        and a CloudWatch console URL — all of it returned to the caller."""
        incomplete = {k: v for k, v in ORDER.items() if k != "discount_pct"}
        response, parsed, runtime = call(proxy, {"instances": [incomplete]})

        assert response["statusCode"] == 400
        assert "discount_pct" in parsed["error"]
        assert runtime.last_call is None, "the endpoint must not be woken for this"

    def test_missing_field_names_the_offending_instance(self, proxy):
        response, parsed, _ = call(proxy, {"instances": [ORDER, {"region": "EMEA"}]})
        assert response["statusCode"] == 400
        assert "instance 1" in parsed["error"]

    def test_oversized_batch_is_rejected(self, proxy):
        response, parsed, runtime = call(proxy, {"instances": [ORDER] * 4})
        assert response["statusCode"] == 400
        assert "too many instances" in parsed["error"]
        assert runtime.last_call is None


class TestEndpointFailures:
    def test_model_error_becomes_400_without_echoing_the_model(self, proxy):
        """SageMaker wraps the container's response, and that wrapper carries the
        account id, the endpoint name and a console URL. None of it may reach an
        external caller — the predictable case is already handled at the edge."""
        module, runtime = proxy
        runtime.raise_error = FakeClientError(
            "ModelError",
            'Received server error (500) from model with message "<!DOCTYPE HTML>...". '
            "See https://us-east-1.console.aws.amazon.com/cloudwatch/home"
            "#logEventViewer:group=/aws/sagemaker/Endpoints/sandbox-dev-refund-risk "
            "in account 823878989845 for more information.",
        )
        response, parsed, _ = call(proxy, {"instances": [ORDER]})

        assert response["statusCode"] == 400
        body = response["body"]
        for leak in ("823878989845", "console.aws.amazon.com", "DOCTYPE", "sandbox-dev-refund-risk"):
            assert leak not in body, f"leaked {leak!r} to the caller"

    @pytest.mark.parametrize(
        "code", ["ServiceUnavailable", "ThrottlingException", "ModelNotReadyException"]
    )
    def test_cold_start_becomes_503_with_retry_advice(self, proxy, code):
        module, runtime = proxy
        runtime.raise_error = FakeClientError(code)
        response, parsed, _ = call(proxy, {"instances": [ORDER]})
        assert response["statusCode"] == 503
        assert "retry" in parsed["error"]

    def test_unexpected_errors_do_not_leak_internals(self, proxy):
        module, runtime = proxy
        runtime.raise_error = FakeClientError(
            "AccessDeniedException",
            "User arn:aws:sts::123456789012:assumed-role/secret-role is not authorized",
        )
        response, parsed, _ = call(proxy, {"instances": [ORDER]})
        assert response["statusCode"] == 502
        # An external caller learns that it failed, and nothing else.
        assert parsed == {"error": "prediction failed"}
        assert "arn:aws" not in response["body"]
        assert "secret-role" not in response["body"]
