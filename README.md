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
- **Transformations under review:** [docs/proposed-transformations.md](./docs/proposed-transformations.md) (`TR-##`)
- **Every AI prompt and output:** [AI_USAGE.md](./AI_USAGE.md)

---

## Quick start

Assuming the [toolchain](#1-install-the-toolchain) is installed and the
[state bucket](#4-create-the-terraform-state-bucket) exists. This is the whole
path on a clean AWS account, in order:

```bash
git clone <repo-url> && cd sandbox
make install                        # venv, dependencies, pre-commit hooks
aws sso login --profile <profile>   # or export credentials
make preflight                      # confirm the toolchain and credentials

make deploy                         # terraform init + apply — also seeds the sample data
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

### 5. Things Terraform cannot do for you

Terraform creates everything in this project, but a few AWS-side conditions sit
outside any configuration. Most accounts already satisfy them; these are the
ones to check when something fails in a way the error message does not explain.

| What | Why Terraform cannot | When it bites |
|---|---|---|
| **The state backend bucket** | It would have to hold the state describing itself | Always — step 4 above |
| **Valid credentials** | Interactive login | Always |
| **Service quotas** | Quotas are account limits, not resources. A new account can have a quota of zero for an instance family | `make train` fails with `ResourceLimitExceeded`, or the Redshift workgroup will not reach `AVAILABLE` |
| **Cost Explorer** | Must be enabled once in the billing console, and takes up to 24 hours to populate | Needed before an AWS Budget (T-6.3) reports anything |
| **Billing access for non-root principals** | Enabled by the root user in Account Settings | You cannot see costs, or a budget cannot be created |
| **Three usable availability zones** | Redshift Serverless requires them; a region or account may offer fewer | The workgroup fails to create |
| **A globally unique bucket name** | S3 names are global, and `bucket_suffix` is the owner tag, not the account id | `BucketAlreadyExists` on the very first apply |

**Quotas are the most likely of these to surprise you.** Check the ones this
project uses before a first deploy in an unfamiliar account:

```bash
# SageMaker training instances — commonly 0 in a new account
aws service-quotas list-service-quotas --service-code sagemaker \
  --query "Quotas[?contains(QuotaName, 'ml.m5.large for training')].{Name:QuotaName,Value:Value}"

# Redshift Serverless capacity
aws service-quotas list-service-quotas --service-code redshift-serverless \
  --query "Quotas[].{Name:QuotaName,Value:Value}" --output table
```

Raise one in the Service Quotas console, or with
`aws service-quotas request-service-quota-increase`. An increase is a support
request and is not instant.

**One thing Terraform does that reaches beyond this project:** it sets
`aws_api_gateway_account`, the account-wide CloudWatch Logs role for API
Gateway. Destroying this stack disables API Gateway logging for the whole
account, and another stack setting it would conflict. Fine in a dedicated
account — see T-5.15 before using a shared one.

### 6. Check everything before you deploy

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
[Deploy the model](#6-deploy-the-model)).

---

## Running the pipeline

Each stage has its own target, so you can run one or all of them.

```bash
make data     # = land + etl + migrate + load
```

**On a fresh environment, `make data` is the one you want.** `make rebuild` does
the same work plus clearing a stale catalog table and dropping `landing.orders`
first — both no-ops on a clean account, and only needed after a *transform
change* has left artefacts written by an older version of the job. Use it when a
load fails on a column that should exist.

### 1. Land the data

**`terraform apply` already did this.** The committed sample file is uploaded
into the raw zone as part of the apply, so a fresh environment can run the rest
of the pipeline with no landing step.

To land it again, or to land something else:

```bash
make land                                    # re-upload the sample file
aws s3 cp ./other.csv "s3://$(terraform -chdir=envs/dev output -raw raw_bucket_name)/takehome/orders/"
```

Raw is flat — no date in the path; the date belongs to the *run*. See
[docs/data-layout.md](./docs/data-layout.md).

> **The seeded file is a fixture, not an ingestion mechanism.** Terraform owns
> that one object, so it restores it on apply and removes it on destroy. A real
> feed must not be managed this way — set `seed_sample_data = false`, and note
> that until you do, replacing that exact key by hand will be reverted on the
> next apply.

### 2. Transform

```bash
make etl                      # write today's snapshot
make etl DATE=2026-08-24      # write a specific partition
make etl DATE=latest          # redo the most recent load in place
```

Starts the Glue job and waits for it. It reads every file under the dataset
prefix, cleans and types it against a declared schema — nothing is inferred —
and writes Snappy Parquet to one `ingest_date` partition.

What it does to each row, in short: trims every field and lowercases all text;
parses four timestamp formats into a **UTC Unix epoch**, with date-only values
landing at midnight; strips currency symbols; defaults missing integers to NULL
and missing floats to NaN; and adds derived columns for dates, amounts and
flags. The full contract is in
[docs/dataset-takehome-orders.md](./docs/dataset-takehome-orders.md).

Rows that fail validation are **quarantined, not dropped**, under
`_rejected/takehome/orders/…` with a `reject_reason` column naming every reason
that row failed. The run fails if more than `etl_max_reject_pct` of rows are
rejected — a threshold worth re-deriving once you have seen a real run.

### 3. Apply the schema migrations

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

The artifact is a single sklearn `Pipeline` with preprocessing inside it,
including the same text cleaning the ETL applies. Training and inference
therefore share one code path (D-27): a request in mixed case scores identically
to one in lowercase, and `make smoke` checks that. The feature list and that
cleaning live in `ml/features.py`, imported by both entry points — which is also
what makes the fitted pipeline loadable in the inference container.

> The training script reports cross-validated metrics and warns when the dataset
> is too small for them to mean anything. Treat the pipeline as the deliverable
> and the score as a by-product until the open questions in
> [proposed-transformations.md](./docs/proposed-transformations.md) are settled —
> TR-16 in particular, since an unconfirmed date convention feeds `order_dow`.

### 6. Deploy the model

```bash
make promote        # approve, and record the ARN in terraform.tfvars
make plan           # review the diff and the plan
make apply
```

`make promote` shows you the candidate version and asks before approving.
**Approving deploys nothing.** On approval it writes
`approved_model_package_arn` into `envs/dev/terraform.tfvars` and prints the
change:

```hcl
approved_model_package_arn = "arn:aws:sagemaker:us-east-1:...:model-package/.../1"
```

Serving a model is therefore still a reviewed diff, not a side effect (D-31) —
the script types the ARN, but nothing reaches the endpoint until you have read
the change and applied it. The first apply creates the endpoint, the Lambda
proxy and the public API; later ones roll the endpoint onto a new version in
place. Clearing the ARN removes the whole inference stack.

### 7. Call it

```bash
make smoke
```

Exercises the public path exactly as an external consumer would. Each line
states what the endpoint is expected to *do*, so `ok` reads as "it did that",
and every check prints the response body — a status code on its own once hid a
400 whose body leaked the AWS account id.

It covers scoring one order and a batch, scoring values the model has never
seen, rejecting an order missing one field and one missing most, rejecting an
empty list and malformed JSON, scoring mixed case identically to lowercase, and
refusing a request with no API key.

By hand:

```bash
URL=$(terraform -chdir=envs/dev output -raw predict_url)
KEY=$(aws apigateway get-api-key \
  --api-key "$(terraform -chdir=envs/dev output -raw predict_api_key_id)" \
  --include-value --query value --output text)

curl -X POST "$URL" -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
  -d '{"instances":[{"region":"emea","channel":"retail","category":"puzzles",
       "quantity":2,"unit_price_usd":30.0,"discount_pct":0.0,
       "shipping_days":4,"order_dow":3}]}'
```

```json
{"predictions": [{"refund_probability": 0.221630}]}
```

Every field above is required; the proxy rejects a request missing any of them
before it reaches the model. The list is
`predict_required_fields` in `envs/dev/terraform.tfvars`, and a test keeps it in
step with the model's features.

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
| Raising a service quota | An account limit, not a resource — and an increase is a support request |
| Enabling Cost Explorer | A billing-console action, and it takes up to 24 hours to populate |
| Approving a model | A human decides a version is fit to serve (D-31). `make promote` records the ARN afterwards, but the decision is the prompt |
| Reviewing and applying that change | Nothing reaches the endpoint until the diff is read and applied (D-07, D-31) |
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

## Why a first apply often fails

Most of what this project configures cannot be validated without calling AWS.
`terraform validate` checks syntax and provider schemas; it does not know that
network isolation is rejected on a serverless endpoint, that API Gateway needs
an account-level logging role before a stage can log, or that a workgroup in
`MODIFYING` refuses statements. Those surface on the first apply, and always
will.

What the project does about it:

| Guard | Catches |
|---|---|
| `make check` | Formatting, provider-schema errors, lint, policy findings, and the fast tests |
| `make test` | The transform, the model, the API proxy and the SQL contract, run locally against the real sample file |
| Drift tests | The feature list disagreeing across the training view, `train.py`, the API contract, the README and the smoke test |
| `make preflight` | Toolchain, credentials, and the state bucket |
| `make verify` | What is actually deployed, including whether the deployed job script matches your working tree |
| `make rebuild` | A schema change reaching catalog, Parquet, table and views in the right order |

**The ordering trap is the one worth internalising.** A change to the transform
has to propagate through the job script, the processed Parquet, the Glue
catalog, the external table, the landing table, the views, the model and the API
contract — in that order. Fixing one link at a time produces a sequence of
unrelated-looking errors. `make rebuild` does the whole chain; `make etl` refuses
to run a job script older than the one in your working tree.

**When something does fail on a first apply, the useful question is whether it
was knowable locally.** If it was, the fix belongs in a test rather than in a
retry.

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

**Every request returns `403 {"message":"Forbidden"}`**
The API key is not being accepted. `make smoke` now checks the key before
running anything and names which of these it is; to check by hand:

```bash
KEY=$(terraform -chdir=envs/dev output -raw predict_api_key_id)

aws apigateway get-api-key --api-key "$KEY" --include-value \
  --query '{enabled:enabled,hasValue:value!=null}'
aws apigateway get-usage-plans --key-id "$KEY" \
  --query 'items[].{plan:name,stages:apiStages}'
```

A key that exists but is attached to no usage plan covering the stage is
refused exactly as no key at all. On a **fresh deploy** the association can take
a short while to propagate, which looks identical — the smoke test retries
during warm-up for that reason, so a first run shortly after `make apply` may
simply need running again.

**`CloudWatch Logs role ARN must be set in account settings to enable logging`**
API Gateway will not attach a log destination to a stage until the account has a
CloudWatch Logs role. This configuration creates one
(`aws_api_gateway_account`) — note it is an **account-wide, region-wide**
setting, so destroying this stack disables API Gateway logging for the whole
account. See T-5.15 before using this in a shared account.

**`column "..." does not exist`, migrating or loading**
The transform changed and something downstream still has the old shape. Which
one depends on where it failed:

| Message names | Stale thing |
|---|---|
| `... in orders` | `landing.orders` — the warehouse table |
| `... in takehome_orders` | the processed Parquet, or its catalog entry |

Both are rebuilt by the same command, which does the whole chain in order:

```bash
make apply          # first, if the job script changed
make rebuild        # reset catalog → re-run ETL → drop → migrate → load
```

Nothing is lost: the processed zone is regenerable from raw, and the warehouse
table is a copy of the processed zone.

`make load` checks the processed columns before it starts, so a stale processed
zone is reported as a list of missing columns and the fix, rather than one
column at a time from Redshift.

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
| `reset-catalog` | `bash scripts/reset_catalog_table.sh` |
| `rebuild` | `reset-catalog`, `etl`, `bash scripts/redshift_sql.sh sql/rebuild_landing_orders.sql`, `migrate`, `load` |
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
ml/                         features.py (the contract), train.py, inference.py
lambda/predict/             API Gateway → SageMaker proxy
sql/                        migrations, the partition load, the training UNLOAD
scripts/                    the manual steps, scripted (see the table above)
tests/                      pytest: helpers, spec invariants, transform, SQL, model, proxy
data/                       the sample dataset
docs/                       data layout and dataset documentation
```
