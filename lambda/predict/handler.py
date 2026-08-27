"""API Gateway -> SageMaker proxy for the refund-risk endpoint.

A SageMaker endpoint cannot be called from outside AWS: every request must be
SigV4-signed. This Lambda is the front door — it holds the IAM identity, and
API Gateway holds the API key and the throttle (D-30).

Deliberately thin. It validates shape and forwards; the feature contract lives
in `ml/inference.py`, next to the model that enforces it. Duplicating field
semantics here would give two places to change and one to forget.

Request:   POST /predict   {"instances": [{...}, ...]}
Response:  200 {"predictions": [{"refund_probability": 0.21}]}
"""

import json
import os

import boto3
from botocore.exceptions import ClientError

ENDPOINT_NAME = os.environ["ENDPOINT_NAME"]
MAX_INSTANCES = int(os.environ.get("MAX_INSTANCES", "100"))

runtime = boto3.client("sagemaker-runtime")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _instances(event):
    """Pull instances out of the request, or raise ValueError with a message
    that is safe to return to an external caller."""
    body = event.get("body")
    if not body:
        raise ValueError("request body is empty")

    if event.get("isBase64Encoded"):
        import base64

        body = base64.b64decode(body).decode("utf-8")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise ValueError(f"body is not valid JSON: {error.msg}")

    if isinstance(payload, dict):
        instances = payload.get("instances", [payload])
    elif isinstance(payload, list):
        instances = payload
    else:
        raise ValueError("expected a JSON object or array")

    if not isinstance(instances, list) or not instances:
        raise ValueError("no instances in request")
    if not all(isinstance(instance, dict) for instance in instances):
        raise ValueError("each instance must be a JSON object")
    if len(instances) > MAX_INSTANCES:
        raise ValueError(f"too many instances: {len(instances)} (limit {MAX_INSTANCES})")

    return instances


def handler(event, context):
    try:
        instances = _instances(event)
    except ValueError as error:
        return _response(400, {"error": str(error)})

    try:
        result = runtime.invoke_endpoint(
            EndpointName=ENDPOINT_NAME,
            ContentType="application/json",
            Accept="application/json",
            Body=json.dumps({"instances": instances}),
        )
        return _response(200, json.loads(result["Body"].read()))

    except ClientError as error:
        code = error.response["Error"]["Code"]

        # The model rejected the payload — the caller's problem, and its message
        # names the missing fields, so it is worth passing back.
        if code == "ModelError":
            return _response(400, {"error": error.response["Error"].get("Message", "invalid input")})

        # A serverless endpoint that has scaled to zero can time out on a cold
        # start. Retrying is the right advice, so say so rather than "500".
        if code in ("ServiceUnavailable", "ThrottlingException", "ModelNotReadyException"):
            print(f"[predict] endpoint unavailable: {code}")
            return _response(503, {"error": "model endpoint is warming up, please retry"})

        # Anything else is ours. Log the detail, return none of it.
        print(f"[predict] invoke failed: {code}: {error}")
        return _response(502, {"error": "prediction failed"})
