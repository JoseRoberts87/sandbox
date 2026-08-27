#!/usr/bin/env bash
#
# Check the toolchain before anything else. Every missing piece is reported with
# how to install it, so one run tells you everything you need rather than
# failing on one tool at a time.
#
#   scripts/preflight.sh
#
# Read-only. It checks versions and whether credentials work; it changes nothing.

set -uo pipefail

cd "$(dirname "$0")/.."

MISSING=0; WARN=0

ok()   { printf '  \033[32mok\033[0m    %-12s %s\n' "$1" "${2:-}"; }
bad()  { printf '  \033[31mmissing\033[0m %-9s %s\n' "$1" "${2:-}"; MISSING=$((MISSING+1)); }
warn() { printf '  \033[33mwarn\033[0m  %-12s %s\n' "$1" "${2:-}"; WARN=$((WARN+1)); }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

group "Required to deploy and run the pipeline"

command -v make >/dev/null 2>&1 \
  && ok make "$(make --version | head -1)" \
  || bad make "see the README — you are reading this via bash, so make is optional here"

if command -v terraform >/dev/null 2>&1; then
  TF_VERSION=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1)
  case "$TF_VERSION" in
    1.1[0-9]*|1.[2-9][0-9]*) ok terraform "$TF_VERSION" ;;
    *) warn terraform "$TF_VERSION — the config pins ~> 1.15, and S3 state locking needs >= 1.10" ;;
  esac
else
  bad terraform "https://developer.hashicorp.com/terraform/install"
fi

if command -v aws >/dev/null 2>&1; then
  AWS_VERSION=$(aws --version 2>&1 | awk '{print $1}')
  case "$AWS_VERSION" in
    aws-cli/2*) ok aws "$AWS_VERSION" ;;
    *) warn aws "$AWS_VERSION — v2 is expected" ;;
  esac
else
  bad aws "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi

if command -v python3 >/dev/null 2>&1; then
  PY_VERSION=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' \
    && ok python3 "$PY_VERSION" \
    || warn python3 "$PY_VERSION — 3.11 or newer expected"
else
  bad python3 ""
fi

group "Required for the commit gate (make check)"

[[ -x venv/bin/pre-commit ]] && ok pre-commit "in venv" \
  || bad pre-commit "run: make install"

command -v tflint >/dev/null 2>&1 && ok tflint "$(tflint --version | head -1)" \
  || bad tflint "brew install tflint  |  https://github.com/terraform-linters/tflint"

command -v checkov >/dev/null 2>&1 && ok checkov "$(checkov --version 2>/dev/null)" \
  || bad checkov "brew install checkov  |  pipx install checkov"

group "Optional"

if command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
  ok java "$(java -version 2>&1 | head -1)"
else
  printf '  \033[33mabsent\033[0m %-10s %s\n' java "Spark tests will skip. Install with: brew install --cask temurin"
fi

group "AWS access"

if IDENTITY=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  ok credentials "account $IDENTITY"

  if aws s3api head-bucket --bucket joseroberts87-tf-backend-etl >/dev/null 2>&1; then
    VERSIONING=$(aws s3api get-bucket-versioning --bucket joseroberts87-tf-backend-etl \
      --query Status --output text 2>/dev/null)
    [[ "$VERSIONING" == "Enabled" ]] \
      && ok "state bucket" "exists, versioning enabled" \
      || warn "state bucket" "exists but versioning is '${VERSIONING:-not set}' — it is the only recovery path from a corrupted state write"
  else
    bad "state bucket" "joseroberts87-tf-backend-etl not reachable — see 'The Terraform state bucket' in the README"
  fi
else
  warn credentials "not valid — run: aws sso login --profile <profile>"
fi

printf '\n'
if [[ "$MISSING" -gt 0 ]]; then
  printf '\033[31m%d required item(s) missing.\033[0m See Prerequisites in the README.\n' "$MISSING"
  exit 1
fi
[[ "$WARN" -gt 0 ]] && printf '\033[33mReady, with %d warning(s).\033[0m\n' "$WARN" \
                    || printf '\033[32mEverything checks out.\033[0m\n'
exit 0
