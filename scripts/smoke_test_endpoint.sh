#!/usr/bin/env bash
#
# End-to-end check of the public prediction API (T-5.5).
#
# Goes through the front door exactly as an external consumer would: HTTPS,
# API key, JSON in, JSON out. Nothing here uses AWS credentials to reach the
# model, which is the point — if this passes, the whole path works.
#
#   scripts/smoke_test_endpoint.sh

set -euo pipefail

cd "$(dirname "$0")/.."

tf_output() { terraform -chdir=envs/dev output -raw "$1" 2>/dev/null; }

if [[ "$(tf_output inference_enabled)" != "true" ]]; then
  echo "error: no approved model is deployed. Set approved_model_package_arn and apply." >&2
  exit 1
fi

URL=$(tf_output predict_url)
KEY_ID=$(tf_output predict_api_key_id)
API_KEY=$(aws apigateway get-api-key --api-key "$KEY_ID" --include-value --query value --output text)

echo "POST $URL"

request() {
  curl -sS -o /tmp/predict_response.json -w '%{http_code}' \
    -X POST "$URL" \
    -H "x-api-key: $API_KEY" \
    -H 'Content-Type: application/json' \
    -d "$1"
}

ACCOUNT_ID=$(tf_output account_id)
ENDPOINT=$(tf_output endpoint_name)

fail=0
check() {
  local name="$1" expected="$2" payload="$3"
  local status body
  status=$(request "$payload")
  body=$(cat /tmp/predict_response.json)

  if [[ "$status" == "$expected" ]]; then
    echo "  ok    $name -> $status"
  else
    echo "  FAIL  $name -> $status (expected $expected)"; fail=1
  fi

  # A correct status code is not a correct response. This caught a 400 whose
  # body carried the AWS account id, the endpoint name and a CloudWatch console
  # URL, passed straight through from the model to an unauthenticated caller.
  for leak in "$ACCOUNT_ID" "$ENDPOINT" "console.aws.amazon.com" "DOCTYPE" "Traceback"; do
    if [[ -n "$leak" && "$body" == *"$leak"* ]]; then
      echo "  FAIL  $name leaked '$leak' in the response body"; fail=1
    fi
  done

  echo "        $body"
  echo
}

# A serverless endpoint that has scaled to zero answers the first call slowly,
# or with a 503. That is expected, not a failure.
echo "warming up (a cold start can take several seconds)"
request '{"instances":[{"region":"EMEA","channel":"retail","category":"puzzles","quantity":1,"unit_price_usd":10.0,"discount_pct":0.0,"order_dow":1}]}' >/dev/null || true

check "valid single order" 200 \
  '{"instances":[{"region":"EMEA","channel":"retail","category":"puzzles","quantity":2,"unit_price_usd":30.0,"discount_pct":0.0,"order_dow":3}]}'

check "batch of two" 200 \
  '{"instances":[{"region":"EMEA","channel":"retail","category":"puzzles","quantity":2,"unit_price_usd":30.0,"discount_pct":0.0,"order_dow":3},{"region":"APAC","channel":"online","category":"digital","quantity":1,"unit_price_usd":9.0,"discount_pct":0.25,"order_dow":6}]}'

# Never-before-seen categorical values must score, not 500. This is the failure
# an endpoint like this hits first in production.
check "unseen category values" 200 \
  '{"instances":[{"region":"ANTARCTICA","channel":"carrier-pigeon","category":"unheard-of","quantity":1,"unit_price_usd":10.0,"discount_pct":0.0,"order_dow":0}]}'

# Caught by the proxy, so this never reaches the model — the message names the
# fields, and nothing from SageMaker's error wrapper appears.
check "missing required field" 400 '{"instances":[{"region":"EMEA"}]}'
check "empty instances"        400 '{"instances":[]}'
check "malformed json"         400 '{not json'

echo "checking the API key is actually required"
status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$URL" \
  -H 'Content-Type: application/json' -d '{"instances":[]}')
if [[ "$status" == "403" ]]; then
  echo "  ok    no api key -> 403"
else
  echo "  FAIL  no api key -> $status (expected 403)"; fail=1
fi

rm -f /tmp/predict_response.json
[[ $fail -eq 0 ]] && echo "all checks passed" || { echo "some checks failed" >&2; exit 1; }
