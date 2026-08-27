# sandbox

A batch ETL pipeline and ML inference API on AWS, defined entirely in Terraform.

Raw CSV lands in **S3**, is cleaned and typed by an **AWS Glue** job, loaded into
**Amazon Redshift** through Spectrum, and used to train a refund-risk model in
**SageMaker** that is served from a serverless endpoint behind **API Gateway**.

```
                                                          ┌─ SageMaker training
                                                          │        │
S3 (raw) ──Glue──► S3 (processed) ──Spectrum──► Redshift ──┘   Model Registry
   CSV              Parquet, partitioned        landing/            │ manual approval
                                                analytics/          ▼
                                                ml/         Serverless endpoint
                                                                    ▲
                              external caller ──► API Gateway ──► Lambda
```

> **Status:** Phases 0–5 are deployed and the pipeline runs end to end — a CSV
> landed in raw comes back out as a calibrated probability from a public API.
> Phase 6 (alarms, budget, runbooks) has not started.

- **Decisions and open questions:** [PROJECT_SCOPE.md](./PROJECT_SCOPE.md) (`D-##`, `Q-##`)
- **Task tracker:** [TODO.md](./TODO.md) (`T-##`)
- **S3 layout and reprocessing semantics:** [docs/data-layout.md](./docs/data-layout.md)
- **The dataset:** [docs/dataset-takehome-orders.md](./docs/dataset-takehome-orders.md)
- **Every AI prompt and output:** [AI_USAGE.md](./AI_USAGE.md)

---

## Quick start

Assuming the [toolchain](#1-install-the-toolchain) is installed and the
[state bucket](#4-create-the-terraform-state-bucket) exists:

```bash
git clone <repo-url> && cd sandbox
make install                        # venv, dependencies, pre-commit hooks
aws sso login --profile <profile>   # or export credentials
make preflight                      # confirm the toolchain and credentials

make deploy                         # terraform init + apply (prompts)
make data                           # land → transform → migrate → load
make model                          # train → approve
#   paste the printed ARN into envs/dev/terraform.tfvars
make apply smoke                    # deploy the endpoint and call it
make verify                         # check the whole thing
```

Starting from nothing, work through [One-time setup](#one-time-setup) first.

`make bootstrap` runs everything up to the manual promotion gate in one go.

Run `make help` for every target.

---

## Prerequisites

| | Tool | Why |
|---|---|---|
| **To deploy and run** | `make`, `git` | Every command in this README |
| | Terraform `~> 1.15` | Pinned in `envs/dev/versions.tf`. Needs ≥ 1.10 for S3-native state locking |
| | AWS CLI **v2** | Every script shells out to it |
| | Python 3.11+ | The test suite, and the training script runs locally unchanged |
| **For `make check`** | `pre-commit` | Installed into the venv by `make install` |
| | `tflint`, `checkov` | The Terraform hooks shell out to them |
| **Optional** | A JVM (17) | Only the Spark tests. They skip cleanly without one |

You can deploy and run the whole pipeline without `tflint`, `checkov` or Java.
They are needed only for the commit gate and the full test suite.

You also need AWS permissions to create S3, KMS, IAM, Glue, VPC, Redshift
Serverless, SageMaker, Lambda and API Gateway resources.

---

## One-time setup

### 1. Install the toolchain

**macOS**

`make` and `git` ship with the Xcode command line tools, which most macs do not
have until asked:

```bash
xcode-select --install

# Homebrew, if you do not have it: https://brew.sh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
brew install awscli python@3.12 tflint checkov

brew install --cask temurin        # optional — only for the Spark tests
```

**Ubuntu / Debian**

```bash
sudo apt-get update
sudo apt-get install -y make git curl unzip python3 python3-venv python3-pip

# Terraform, from HashiCorp's apt repository
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# AWS CLI v2 — the apt package is v1, which is not what the scripts expect
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip

# The commit-gate linters
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
python3 -m pip install --user checkov

sudo apt-get install -y default-jdk    # optional — only for the Spark tests
```

**Fedora / RHEL / Amazon Linux**

```bash
sudo dnf install -y make git python3 unzip dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform
```

Then AWS CLI v2, tflint and checkov exactly as in the Ubuntu block above.

**Windows**

Use **WSL2** and follow the Ubuntu instructions inside it. The scripts here are
bash and rely on POSIX tooling; native Windows is not a supported path.

```powershell
wsl --install -d Ubuntu
```

### 2. Clone and set up the project

```bash
git clone <repo-url>
cd sandbox
make install
```

`make install` creates `venv/`, installs the Python dependencies and
`pre-commit`, and installs the git hooks.

> **No `make`?** Install it above — it is one package everywhere. If you would
> rather not, [Without `make`](#without-make) lists the command behind every
> target.

### 3. Authenticate to AWS

```bash
aws sso login --profile <profile>    # or export AWS_PROFILE / access keys
aws sts get-caller-identity          # confirm the account you expect
```

SSO tokens expire often. Later on, a `plan` failing with `InvalidClientTokenId`
means the token, not the configuration.

### 4. Create the Terraform state bucket

State lives in S3, but **the state bucket is deliberately not managed by this
configuration** — it cannot hold the state that describes itself. Create it once
by hand:

```bash
aws s3api create-bucket --bucket joseroberts87-tf-backend-etl --region us-east-1

# Versioning is not optional. It is the only recovery path from a corrupted
# state write.
aws s3api put-bucket-versioning --bucket joseroberts87-tf-backend-etl \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket joseroberts87-tf-backend-etl \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

If it already exists, confirm versioning is on. To use local state instead, see
[State](#state).

> Using a different bucket name means editing `bucket` in
> `envs/dev/backend.tf`, and the bucket must be in the same region as `region`
> there.

### 5. Check everything before you deploy

```bash
make preflight
```

Reports every missing tool with how to install it, flags a Terraform or AWS CLI
version that will not work, and confirms your credentials and the state bucket.
Fix anything it marks `missing` before continuing.

---

## Deploy

```bash
make deploy          # = terraform init + terraform apply
```

`apply` **prompts for confirmation and is never auto-approved** — a developer
reviews the plan (D-07). To look first:

```bash
make plan
```

This creates everything except the inference stack: buckets, KMS keys, the Glue
job, the VPC, Redshift Serverless, the SageMaker role and the model registry.
The endpoint, Lambda and API Gateway stay absent until a model is approved (see
[Deploy the model](#6-deploy-the-model-two-manual-steps-deliberately)).

---

## Running the pipeline

Each stage has its own target, so you can run one or all of them.

```bash
make data     # = land + etl + migrate + load
```

### 1. Land the data

```bash
make land
```

Uploads `data/dpe_interview_takehome_data.csv` to
`s3://<raw>/takehome/orders/`. Raw is flat — no date in the path; the date
belongs to the *run*. See [docs/data-layout.md](./docs/data-layout.md).

### 2. Transform

```bash
make etl                      # write today's snapshot
make etl DATE=2026-08-24      # write a specific partition
make etl DATE=latest          # redo the most recent load in place
```

Starts the Glue job and waits for it. It reads every file under the dataset
prefix, cleans and types it against the declared schema, and writes Snappy
Parquet to one `ingest_date` partition.

Rows that fail validation are **quarantined, not dropped**, under
`_rejected/takehome/orders/…` with a `reject_reason` column. The run fails if
more than `etl_max_reject_pct` (5%) of rows are rejected. On the sample data
expect 19 rows in, 19 out, 0 rejected.

### 3. Apply the schema migrations — **manual, and not part of `terraform apply`**

```bash
make migrate
```

Terraform owns infrastructure, not schema (D-38). DDL is ordered files in
`sql/migrations/`, applied through the Redshift Data API.

> **This step is easy to miss.** `terraform apply` does not create the schemas.
> If a query returns `schema "analytics" does not exist`, this is why.

Re-runnable: every migration is `CREATE ... IF NOT EXISTS` or
`CREATE OR REPLACE`.

### 4. Load the warehouse

```bash
make load                     # newest partition present in S3
make load DATE=2026-08-24     # a specific one
```

Delete-then-insert for one partition, so re-running a date replaces it rather
than duplicating — the same contract the ETL has with S3.

> **Query `analytics.orders`, never `landing.orders`.** Every partition is a
> *complete snapshot*, so the table holds each order once per ETL run. The view
> pins `MAX(ingest_date)` and is what "the orders table" should mean.

### 5. Train a model

```bash
make train
```

Unloads `ml.orders_training` to `s3://<artifacts>/training/<version>/`, packages
`ml/`, runs a SageMaker training job, and registers the result as
**PendingManualApproval**. Nothing deploys.

The model predicts whether an order will end up refunded, from what is known
when the order is placed. What it learns from — and what it must not see — is
defined in
[`sql/migrations/005_ml_training_view.sql`](./sql/migrations/005_ml_training_view.sql).

> On 19 sample rows this scores an ROC AUC around 0.54 — indistinguishable from
> guessing, and the training script says so itself. The deliverable is the
> pipeline, not the model.

### 6. Deploy the model — **two manual steps, deliberately**

```bash
make promote
```

Approves a registry version. **This deploys nothing.** It prints an ARN; paste
it into `envs/dev/terraform.tfvars`:

```hcl
approved_model_package_arn = "arn:aws:sagemaker:us-east-1:...:model-package/.../1"
```

Then:

```bash
make apply
```

Serving a model is therefore a reviewed diff, not a side effect (D-31). The
first apply creates the endpoint, the Lambda proxy and the public API; later
ones roll the endpoint onto a new version in place. Clearing the ARN removes the
whole inference stack.

### 7. Call it

```bash
make smoke
```

Exercises the public path exactly as an external consumer would: valid single
and batch requests, unseen categorical values, three malformed payloads, and a
request with no API key.

By hand:

```bash
URL=$(terraform -chdir=envs/dev output -raw predict_url)
KEY=$(aws apigateway get-api-key \
  --api-key "$(terraform -chdir=envs/dev output -raw predict_api_key_id)" \
  --include-value --query value --output text)

curl -X POST "$URL" -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
  -d '{"instances":[{"region":"EMEA","channel":"retail","category":"puzzles",
       "quantity":2,"unit_price_usd":30.0,"discount_pct":0.0,"order_dow":3}]}'
```

```json
{"predictions": [{"refund_probability": 0.221630}]}
```

| Response | Meaning |
|---|---|
| `200` | One prediction per instance, in order |
| `400` | Your request — malformed JSON, no instances, missing fields, too many rows |
| `503` | The endpoint scaled to zero and is warming up. Retry |
| `502` | Our side. Detail is in CloudWatch, deliberately not in the response |

> **Cold starts.** The endpoint scales to zero, so the first call after a quiet
> period takes several seconds. That is the trade for costing nothing while idle.

---

## Every manual step, in one place

These are the things no target can do for you, and why.

| Step | Why it is manual |
|---|---|
| Create the state bucket | It would have to hold the state describing itself |
| `aws sso login` | Interactive |
| `terraform apply` | A developer reviews the plan (D-07). Never auto-approved |
| `make migrate` | Terraform does not own schema (D-38). Automated by `make data`, but never by an apply |
| Approving a model | A human decides a version is fit to serve (D-31) |
| Editing `approved_model_package_arn` | Keeps the deployed version in a reviewed diff (D-31) |
| Committing and pushing | Never done unprompted (D-08) |

---

## Verification

```bash
make verify
```

Checks, and reports all failures rather than stopping at the first: Terraform
outputs resolve and show no drift; raw holds a file; processed has partitions;
nothing is quarantined; the schemas exist; Spectrum can read the Parquet;
`analytics.orders` filters to the newest snapshot; model versions exist; the
endpoint is `InService`; and the cost guards are in place (no NAT gateway,
schedule disabled, Redshift usage limit set).

Ad-hoc queries:

```bash
make query SQL="SELECT region, count(*) FROM analytics.orders GROUP BY 1"
```

Local gates, no AWS needed:

```bash
make check        # terraform fmt/validate/tflint/checkov + fast tests
make test         # full suite (Spark tests skip without a JVM)
make test-fast    # the ~0.1s subset
```

---

## Day to day

**Reprocess a date.** Both stages are idempotent, so this replaces rather than
duplicates:

```bash
make etl DATE=2026-08-24
make load DATE=2026-08-24
```

**Land new data and rerun:**

```bash
aws s3 cp ./new_orders.csv "s3://$(terraform -chdir=envs/dev output -raw raw_bucket_name)/takehome/orders/"
make etl load
```

**Retrain and redeploy:**

```bash
make train promote
# update approved_model_package_arn, then
make apply smoke
```

**Discover the schema of an unfamiliar file:**

```bash
aws glue start-crawler --name "$(terraform -chdir=envs/dev output -raw glue_raw_crawler_name)"
```

The crawler is for exploration only — nothing downstream reads a crawled table.

---

## State

| | |
|---|---|
| Bucket | `joseroberts87-tf-backend-etl` |
| Key | `envs/dev/terraform.tfstate` |
| Locking | S3-native conditional writes — no DynamoDB table |

Declared in `envs/dev/backend.tf`, in its own file so switching modes is a
rename rather than an edit inside a block.

**To use local state instead:**

```bash
cd envs/dev
mv backend.tf backend.tf.disabled
terraform init -migrate-state
```

Reverse to go back. `backend.tf.disabled` is gitignored and `*.tfstate` is never
committed in either mode.

Remote is right for anything shared: it survives a lost laptop, it locks so two
applies cannot race, and it is versioned. Local is for throwaway work you are
willing to lose.

---

## Cost

An idle environment costs roughly two KMS keys — a couple of dollars a month.
What can change that:

| Component | Guard |
|---|---|
| **Redshift Serverless** | 8 RPU floor, and a monthly RPU-hour limit set to **deactivate** on breach. If queries suddenly fail, check the usage limit before assuming an outage |
| **Glue** | Schedule created **disabled** until a cadence is settled (Q-08) |
| **Inference endpoint** | Serverless — scales to zero, costs nothing idle |
| **API Gateway** | API key with a daily quota; the endpoint scales with demand, so an unmetered key is an unmetered bill |
| **Networking** | No NAT gateway. `make verify` checks this |

**Teardown:**

```bash
make destroy
```

Buckets must be emptied first unless `force_destroy_buckets = true`.

---

## Troubleshooting

**`schema "analytics" does not exist`**
The migrations have not been applied. `terraform apply` does not create schemas
(D-38). Run `make migrate`.

**A load fails with `AwsClientException ... curlError=Connection timeout`**
The `DELETE` succeeds and the `INSERT ... SELECT` times out after 30 seconds.
Spectrum could not reach what it needed from inside the VPC. Check
`redshift_enhanced_vpc_routing` in `terraform.tfvars` — with it on, Spectrum's
traffic is subject to a VPC that can reach S3 and nothing else, and resolving an
external table also needs the Glue catalog. It ships **off** for this reason;
turning it on requires the interface endpoints in T-3.14.

Nothing partial lands: the Data API runs a file's statements in one
transaction, so a failed `INSERT` rolls the `DELETE` back with it.

**`ValidationException: Redshift endpoint is not available`**
The workgroup is not `AVAILABLE`. Changing capacity or
`enhanced_vpc_routing` puts it in `MODIFYING` for several minutes, during which
it rejects statements. `make migrate`, `make load` and `make query` now wait for
it; if you hit this from a raw `aws redshift-data` call, check:

```bash
aws redshift-serverless get-workgroup \
  --workgroup-name "$(terraform -chdir=envs/dev output -raw redshift_workgroup_name)" \
  --query workgroup.status
```

If the status is neither `AVAILABLE` nor `MODIFYING`, see the usage-limit note
below.

**`The network isolation is not supported for serverless endpoint`**
`endpoint_network_isolation` must stay `false` while the endpoint is serverless
— the API rejects it outright. It ships `false`; the variable exists only for a
future provisioned endpoint, where isolation is supported.

**`Cannot create already existing model`**
The SageMaker model's name is derived from a hash of everything that defines it,
so a replacement always gets a distinct name. If you add an argument to
`aws_sagemaker_model`, add it to `local.model_fingerprint` too — otherwise a
change that forces replacement will not change the name, and the create will
collide with the model still being destroyed.

If a model was left behind by a failed apply, it is safe to delete once nothing
references it:

```bash
aws sagemaker list-models --name-contains refund-risk \
  --query 'Models[].ModelName'
aws sagemaker delete-model --model-name <orphan>
```

**`CloudWatch Logs role ARN must be set in account settings to enable logging`**
API Gateway will not attach a log destination to a stage until the account has a
CloudWatch Logs role. This configuration creates one
(`aws_api_gateway_account`) — note it is an **account-wide, region-wide**
setting, so destroying this stack disables API Gateway logging for the whole
account. See T-5.15 before using this in a shared account.

**`InvalidClientTokenId` from `terraform plan`**
The SSO token expired. `aws sso login --profile <profile>`.

**Queries suddenly fail for no clear reason**
Check the Redshift usage limit before assuming an outage — it is set to
**deactivate** the workgroup when the monthly RPU-hour allowance is breached.

```bash
aws redshift-serverless list-usage-limits --resource-arn "$(aws redshift-serverless \
  get-workgroup --workgroup-name "$(terraform -chdir=envs/dev output -raw redshift_workgroup_name)" \
  --query workgroup.workgroupArn --output text)"
```

**The first API call after a quiet period returns 503**
The inference endpoint scaled to zero and is warming up. Retry; `make smoke`
warms it before asserting.

**A Glue run fails**
The job's own messages are prefixed `[raw_to_processed]`:

```bash
aws logs tail /aws-glue/jobs/output --log-stream-name-prefix <run-id>
```

Rows it rejected are under `_rejected/` in the processed bucket with a
`reject_reason` column.

---

## Without `make`

Every target is a thin wrapper. If you would rather not install `make`, or want
to see what a target actually does, this is the whole mapping.

| Target | Command |
|---|---|
| `preflight` | `bash scripts/preflight.sh` |
| `install` | `python3 -m venv venv && venv/bin/python -m pip install -r requirements-dev.txt && venv/bin/pre-commit install` |
| `check` | `venv/bin/pre-commit run --all-files` |
| `test` | `venv/bin/python -m pytest` |
| `test-fast` | `venv/bin/python -m pytest -m "not spark"` |
| `fmt` | `terraform fmt -recursive` |
| `init` | `terraform -chdir=envs/dev init` |
| `plan` | `terraform -chdir=envs/dev plan` |
| `apply` | `terraform -chdir=envs/dev apply` |
| `output` | `terraform -chdir=envs/dev output` |
| `destroy` | `terraform -chdir=envs/dev destroy` |
| `land` | `bash scripts/land_sample_data.sh` |
| `etl` | `bash scripts/run_etl.sh [DATE]` |
| `migrate` | `bash scripts/redshift_sql.sh sql/migrations` |
| `load` | `bash scripts/load_warehouse.sh [DATE]` |
| `train` | `bash scripts/train_model.sh` |
| `promote` | `bash scripts/promote_model.sh` |
| `smoke` | `bash scripts/smoke_test_endpoint.sh` |
| `verify` | `bash scripts/verify.sh` |
| `query` | `bash scripts/redshift_query.sh "SELECT ..."` |
| `clean` | `rm -rf .pytest_cache envs/dev/.terraform/predict_lambda.zip` and `__pycache__` dirs |

The composites are just sequences:

| Target | Runs |
|---|---|
| `deploy` | `init` then `apply` |
| `data` | `land`, `etl`, `migrate`, `load` |
| `model` | `train` then `promote` |
| `bootstrap` | `deploy`, `data`, `model`, then stops at the promotion gate |

---

## Project structure

```
Makefile                    every command; `make help` lists them
envs/dev/                   the root module — one directory per environment
  backend.tf                remote state; remove this file to go local
  main.tf kms.tf storage.tf glue.tf iam.tf
  network.tf redshift.tf sagemaker.tf inference.tf api.tf
modules/s3_bucket/          private, encrypted bucket used for all three zones
glue/jobs/                  the PySpark ETL job
ml/                         train.py and inference.py — run locally and in SageMaker
lambda/predict/             API Gateway → SageMaker proxy
sql/                        migrations, the partition load, the training UNLOAD
scripts/                    the manual steps, scripted (see the table above)
tests/                      pytest: helpers, spec invariants, transform, model, proxy
data/                       the sample dataset
docs/                       data layout and dataset documentation
```
