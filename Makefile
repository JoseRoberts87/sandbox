# Automation for the ETL + ML pipeline. `make help` lists everything.
#
# Two rules this file deliberately does not automate away:
#
#   * `apply` never passes -auto-approve. A developer reviews the plan (D-07).
#   * Promoting a model means editing terraform.tfvars by hand, so the deployed
#     version lives in a reviewed diff (D-31). `make promote` prints the line.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF      := terraform -chdir=envs/dev
VENV    := venv
PY      := $(VENV)/bin/python
PYTEST  := $(PY) -m pytest
PRECOMMIT := $(VENV)/bin/pre-commit

# Optional partition override:  make etl DATE=2026-08-24
DATE ?=

.PHONY: help preflight install check test test-fast fmt \
        init plan apply output destroy \
        land etl migrate load train promote smoke verify query \
        deploy data model bootstrap clean

help: ## Show this help
	@echo "ETL + ML pipeline on AWS"
	@echo
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Partition override:  make etl DATE=2026-08-24"
	@echo

##@ Setup
preflight: ## Check every required tool is installed and credentials work
	scripts/preflight.sh

install: ## Create the venv, install dependencies and pre-commit hooks
	python3 -m venv $(VENV)
	$(PY) -m pip install --quiet --upgrade pip
	$(PY) -m pip install --quiet -r requirements-dev.txt
	$(PRECOMMIT) install
	@echo
	@echo "Installed. Check the rest of the toolchain with:  make preflight"

check: ## Run every gate: terraform fmt/validate/tflint/checkov + fast tests
	@test -x $(PRECOMMIT) || { echo "run 'make install' first" >&2; exit 1; }
	$(PRECOMMIT) run --all-files

test: ## Run the full test suite (needs a JVM for the Spark tests)
	$(PYTEST)

test-fast: ## Run only the tests that need no JVM (~0.1s)
	$(PYTEST) -m "not spark"

fmt: ## Format Terraform in place
	terraform fmt -recursive

##@ Infrastructure
init: ## Initialise Terraform against the S3 backend
	$(TF) init

plan: ## Show what an apply would change
	$(TF) plan

apply: ## Apply infrastructure — prompts for confirmation, by design (D-07)
	$(TF) apply

output: ## Print all Terraform outputs
	$(TF) output

destroy: ## Tear down. Buckets must be emptied first unless force_destroy_buckets=true
	@echo "This destroys the environment. Data in S3 and Redshift goes with it."
	$(TF) destroy

##@ Pipeline
land: ## Upload the sample dataset to the raw zone
	scripts/land_sample_data.sh

etl: ## Run the Glue job and wait for it  [DATE=YYYY-MM-DD|latest]
	scripts/run_etl.sh $(DATE)

migrate: ## Apply the Redshift schema migrations (not done by terraform apply)
	scripts/redshift_sql.sh sql/migrations

load: ## Load a processed snapshot into Redshift  [DATE=YYYY-MM-DD]
	scripts/load_warehouse.sh $(DATE)

train: ## Unload the training set, train, and register a candidate version
	scripts/train_model.sh

promote: ## Approve a version, then print the tfvars line that deploys it
	scripts/promote_model.sh

smoke: ## Call the public prediction API the way an external consumer would
	scripts/smoke_test_endpoint.sh

##@ Verification
verify: ## Check what is deployed and working, end to end
	scripts/verify.sh

query: ## Run one SQL statement:  make query SQL="SELECT 1"
	@test -n "$(SQL)" || { echo 'usage: make query SQL="SELECT ..."' >&2; exit 1; }
	@scripts/redshift_query.sh "$(SQL)"

##@ Composite
deploy: init apply ## Initialise and apply infrastructure

data: land etl migrate load ## Run the whole data path: land, transform, migrate, load

model: train promote ## Train a candidate and approve it

bootstrap: deploy data model ## Everything up to the manual promotion gate
	@echo
	@echo "Infrastructure is up and the warehouse is loaded."
	@echo
	@echo "One manual step remains, deliberately (D-31): paste the model package"
	@echo "ARN printed above into envs/dev/terraform.tfvars as"
	@echo
	@echo "    approved_model_package_arn = \"arn:aws:sagemaker:...\""
	@echo
	@echo "then:  make apply smoke"

clean: ## Remove local build artefacts (not the venv, not any AWS resource)
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	rm -rf .pytest_cache envs/dev/.terraform/predict_lambda.zip
