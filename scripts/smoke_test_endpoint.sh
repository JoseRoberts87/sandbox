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
passed=0
failed=0

# Each label states what the endpoint is expected to *do*, so "ok" reads as
# "it did that" rather than leaving the reader to work out whether a 400 was
# the point. Every check prints the response body — a status code alone once
# hid a 400 whose body leaked the AWS account id.
check() {
  local name="$1" expected="$2" payload="$3"
  local status body
  status=$(request "$payload")
  body=$(cat /tmp/predict_response.json)

  if [[ "$status" == "$expected" ]]; then
    printf '  \033[32mok\033[0m    %s  [%s]\n' "$name" "$status"
    passed=$((passed + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s  [%s, expected %s]\n' "$name" "$status" "$expected"
    fail=1
    failed=$((failed + 1))
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

# Every field the proxy requires. Kept as one definition so the cases below
# vary only what they are testing — a payload that quietly falls behind the
# model's features fails as three confusing 400s.
ORDER='{"region":"emea","channel":"retail","category":"puzzles","quantity":2,"unit_price_usd":30.0,"discount_pct":0.0,"shipping_days":4,"order_dow":3}'
OTHER='{"region":"apac","channel":"online","category":"digital","quantity":1,"unit_price_usd":9.0,"discount_pct":0.25,"shipping_days":12,"order_dow":6}'

# Fail early and clearly if this script has fallen behind the deployed contract,
# rather than reporting every case as a failure.
REQUIRED=$(terraform -chdir=envs/dev output -json predict_required_fields 2>/dev/null \
  | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))' 2>/dev/null) || REQUIRED=""
for field in $REQUIRED; do
  if [[ "$ORDER" != *"\"$field\""* ]]; then
    echo "error: this script's payload is missing '$field', which the API requires." >&2
    echo "Add it to ORDER and OTHER above." >&2
    exit 1
  fi
done

# A serverless endpoint that has scaled to zero answers the first call slowly,
# or with a 503. That is expected, not a failure.
echo "warming up (a cold start can take several seconds)"
request "{\"instances\":[$ORDER]}" >/dev/null || true

check "scores one order"                    200 "{\"instances\":[$ORDER]}"
check "scores a batch, one result per order" 200 "{\"instances\":[$ORDER,$OTHER]}"

# Never-before-seen categorical values must score, not 500. This is the failure
# an endpoint like this hits first in production.
check "scores values it has never seen"      200 \
  '{"instances":[{"region":"antarctica","channel":"carrier-pigeon","category":"unheard-of","quantity":1,"unit_price_usd":10.0,"discount_pct":0.0,"shipping_days":3,"order_dow":0}]}'

# Caught by the proxy, so these never reach the model — the message names the
# fields, and nothing from SageMaker's error wrapper appears.
#
# One field omitted from an otherwise complete order, which is the realistic
# mistake. The label used to say "missing required field" while sending a
# payload that omitted seven, so a reader could not tell what had been tested.
ONE_MISSING=$(printf '%s' "$ORDER" | sed 's/,"discount_pct":0.0//')
check "rejects an order missing one field"   400 "{\"instances\":[$ONE_MISSING]}"
check "rejects an order missing most fields" 400 '{"instances":[{"region":"emea"}]}'
check "rejects an empty instances list"      400 '{"instances":[]}'
check "rejects malformed JSON"               400 '{not json'

# The ETL lowercases all text, so the model learned from lowercase values. The
# pipeline normalises its input for the same reason, and this proves it: a
# caller shouting must get the same answer, not a silently degraded one.
# The ETL lowercases all text, so the model learned from lowercase values. The
# pipeline normalises its input for the same reason, and this proves it: a
# caller shouting must get the same answer, not a silently degraded one.
SHOUTY=$(printf '%s' "$ORDER" | sed 's/"emea"/"  EMEA  "/; s/"retail"/"Retail"/; s/"puzzles"/"PUZZLES"/')
request "{\"instances\":[$ORDER]}"  >/dev/null; LOWER=$(cat /tmp/predict_response.json)
request "{\"instances\":[$SHOUTY]}" >/dev/null; MIXED=$(cat /tmp/predict_response.json)

if [[ "$LOWER" == "$MIXED" ]]; then
  printf '  \033[32mok\033[0m    %s\n' "scores mixed case identically to lowercase"
  passed=$((passed + 1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "mixed case changed the prediction — training/serving skew"
  fail=1
  failed=$((failed + 1))
fi
echo "        lowercase: $LOWER"
echo "        mixed    : $MIXED"
echo

status=$(curl -sS -o /tmp/predict_response.json -w '%{http_code}' -X POST "$URL" \
  -H 'Content-Type: application/json' -d "{\"instances\":[$ORDER]}")
if [[ "$status" == "403" ]]; then
  printf '  \033[32mok\033[0m    %s  [403]\n' "rejects a request with no API key"
  passed=$((passed + 1))
else
  printf '  \033[31mFAIL\033[0m  %s  [%s, expected 403]\n' "no API key" "$status"
  fail=1
  failed=$((failed + 1))
fi
echo "        $(cat /tmp/predict_response.json)"
echo

rm -f /tmp/predict_response.json

total=$((passed + failed))
rule="────────────────────────────────────────────────────────────────"

if [[ "$fail" -eq 0 ]]; then
  printf '\033[32m%s\n' "$rule"
  printf '  PASSED — %d of %d checks\n\n' "$passed" "$total"
  printf '  The public endpoint is live and serving predictions.\n'
  printf '  Reachable from outside AWS, over HTTPS, with an API key:\n'
  printf '    %s\n' "$URL"
  printf '%s\033[0m\n' "$rule"
else
  printf '\033[31m%s\n' "$rule" >&2
  printf '  FAILED — %d of %d checks failed\n\n' "$failed" "$total" >&2
  printf '  Each failing line above shows what came back. A 5xx means the\n' >&2
  printf '  endpoint or the proxy; a wrong 4xx means the request contract.\n' >&2
  printf '%s\033[0m\n' "$rule" >&2
  exit 1
fi
