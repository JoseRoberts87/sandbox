# sandbox

A batch ETL pipeline and ML inference API on AWS, defined entirely in Terraform.

Raw data lands in **S3**, is transformed by **AWS Glue** ETL jobs, loaded into
**Amazon Redshift**, and used to train a model in **Amazon SageMaker**, which
serves predictions from an inference endpoint.

> **Status:** Phases 0–1 (Terraform foundations, raw bucket) are applied.
> Phase 2 (Glue ETL) is written and validated, not yet applied.
> Architecture and decisions are in [PROJECT_SCOPE.md](./PROJECT_SCOPE.md);
> progress and next actions are in [TODO.md](./TODO.md).

## Architecture

```
S3 (raw) ──Glue──► S3 (processed) ──COPY──► Redshift ──UNLOAD──► SageMaker ──► inference endpoint
   ▲          ▲            ▲
   └── built  └── built    └── built (not applied)
```

Layout — see [docs/data-layout.md](./docs/data-layout.md):

```
raw        <source>/<dataset>/<file>
processed  <source>/<dataset>/ingest_date=YYYY-MM-DD/*.parquet
```

Raw is flat; a run reads the whole dataset prefix and writes a complete snapshot
to the `ingest_date` partition for that run. Read the newest partition, not all
of them.

## How this project is built

- **Terraform** defines all infrastructure. It is applied **manually** by a
  developer after reviewing the plan — there is no CI/CD deployment.
- **Commits are manual.**
- Components are built **one at a time**, in the phase order defined in the
  project scope. Each phase is applied and verified before the next begins.
- **State lives in S3** (`joseroberts87-tf-backend-etl`), with S3-native locking.
  Running against local state is still supported — see [State](#state).

## Requirements

| Tool | Version |
|---|---|
| Terraform | >= 1.9.0 (1.15.8 in use) |
| AWS CLI | v2 |
| AWS credentials | An account with permission to create S3, KMS, IAM, Glue and Scheduler resources |

## Setup

```bash
git clone <repo-url>
cd sandbox

aws sso login --profile <your-profile>     # or export AWS_PROFILE / access keys
aws sts get-caller-identity                # confirm the target account
```

## State

Terraform state is held remotely by default:

| | |
|---|---|
| Bucket | `joseroberts87-tf-backend-etl` |
| Key | `envs/dev/terraform.tfstate` |
| Region | `us-east-1` |
| Locking | S3-native conditional writes (`use_lockfile`) — no DynamoDB table |
| Encryption | `encrypt = true` |

The backend is declared in `envs/dev/backend.tf`, deliberately in its own file so
switching modes is a file-level toggle rather than an edit inside a block.

The state bucket is **not managed by this configuration** — it cannot be, since
it would hold the state describing itself. Create it once by hand, and make sure
it has **versioning enabled**: that is the only thing between a corrupted apply
and an unrecoverable environment. Block public access and enable encryption too.

### Using remote state (default)

```bash
cd envs/dev
terraform init        # first time on a machine, or after changing the backend
terraform plan
```

### Migrating local state to S3 (one time)

```bash
cd envs/dev

# 1. Keep a copy. If the migration goes wrong this file is the way back.
cp terraform.tfstate "terraform.tfstate.backup-$(date -u +%Y%m%dT%H%M%SZ)"

# 2. Terraform detects the new backend and offers to copy existing state up.
#    Answer "yes" at the prompt.
terraform init -migrate-state

# 3. Verify before trusting it: same resources, and nothing to change.
terraform state list
terraform plan        # expect "No changes"

# 4. Only then remove the local copies.
rm -f terraform.tfstate terraform.tfstate.backup
```

If step 3 shows resources missing or a plan that wants to recreate things,
**stop** — restore the backup from step 1 and re-check the bucket, key and region
before trying again.

### Using local state instead

```bash
cd envs/dev
mv backend.tf backend.tf.disabled
terraform init -migrate-state     # pulls state down into ./terraform.tfstate
```

To go back:

```bash
mv backend.tf.disabled backend.tf
terraform init -migrate-state
```

`backend.tf.disabled` is gitignored, and `*.tfstate` never gets committed in
either mode.

### Which to use

Remote for anything shared or real: it survives a lost laptop, it locks so two
applies cannot race, and it is versioned. Local only for a throwaway environment
you are willing to lose — with local state, `envs/dev/terraform.tfstate` is the
single copy of the record of what exists, and applying from a second machine will
silently diverge.

## Usage

### Deploying

```bash
cd envs/dev

terraform init      # first time, and after any module/provider change
terraform plan      # review before every apply
terraform apply     # manual, per D-07

terraform output    # bucket names, Glue job name, catalog databases
```

### Landing data

Raw is flat: a file goes under its dataset prefix with no date in the path. The
job derives that prefix from `--source_name` and `--dataset`, so it must match
`etl_source_name` / `etl_dataset` in `envs/dev/terraform.tfvars`:

```
<source>/<dataset>/<file>
```

For the sample dataset:

```bash
scripts/land_sample_data.sh
```

Anything else, by hand:

```bash
RAW=$(terraform -chdir=envs/dev output -raw raw_bucket_name)

aws s3 cp ./orders_20260826.csv "s3://$RAW/takehome/orders/orders_20260826.csv"
```

### Running the ETL

A run reads every file under the dataset prefix and writes a complete snapshot
to one `ingest_date` partition — today's, unless told otherwise:

```bash
JOB=$(terraform -chdir=envs/dev output -raw glue_job_name)

aws glue start-job-run --job-name "$JOB"

# redo the most recent load in place, whatever date it was written under
aws glue start-job-run --job-name "$JOB" --arguments '{"--ingest_date":"latest"}'

# write a specific partition — reruns of a date replace it rather than duplicating
aws glue start-job-run --job-name "$JOB" \
  --arguments '{"--ingest_date":"2026-08-24"}'

# a different dataset
aws glue start-job-run --job-name "$JOB" \
  --arguments '{"--source_name":"acme_crm","--dataset":"customers","--source_format":"csv"}'
```

Watch a run:

```bash
aws glue get-job-runs --job-name "$JOB" --max-items 1
aws logs tail /aws-glue/jobs/output --follow
```

### Testing the job end to end

```bash
# 1. Apply — this also uploads the current job script to the artifacts bucket,
#    so run it after any change to glue/jobs/raw_to_processed.py
terraform -chdir=envs/dev apply

# 2. Land the sample data at the expected prefix
scripts/land_sample_data.sh

# 3. Run the job over the partition just landed
JOB=$(terraform -chdir=envs/dev output -raw glue_job_name)
RUN=$(aws glue start-job-run --job-name "$JOB" --query JobRunId --output text)

# 4. Watch it
aws glue get-job-run --job-name "$JOB" --run-id "$RUN" \
  --query 'JobRun.{State:JobRunState,Error:ErrorMessage}'
aws logs tail /aws-glue/jobs/output --follow

# 5. Confirm the output landed in the right partition
PROCESSED=$(terraform -chdir=envs/dev output -raw processed_bucket_name)
aws s3 ls "s3://$PROCESSED/takehome/orders/" --recursive

# 6. Confirm the catalog table was created
aws glue get-table \
  --database-name "$(terraform -chdir=envs/dev output -raw glue_processed_database)" \
  --name takehome_orders --query 'Table.StorageDescriptor.Columns[].Name'
```

Expect 19 rows accepted and no rejects. Anything quarantined appears under
`s3://$PROCESSED/_rejected/takehome/orders/` with a `reject_reason` column, and
the run fails if more than `etl_max_reject_pct` of rows are rejected.

Rerunning the same date replaces that partition rather than appending, so step 3
is safe to repeat.

> Querying the processed table in Athena needs an Athena workgroup and a results
> bucket, neither of which exists yet. The `aws glue get-table` check above
> verifies the catalog without them.

### Discovering a schema

The raw crawler is on-demand and exists only to answer "what is actually in this
file". Nothing downstream reads a crawled table.

```bash
aws glue start-crawler --name "$(terraform -chdir=envs/dev output -raw glue_raw_crawler_name)"
```

### Tearing down

```bash
cd envs/dev
# Buckets must be emptied first unless force_destroy_buckets = true
terraform destroy
```

With remote state, `terraform destroy` is still irreversible for the data in the
buckets — emptying them is a separate, deliberate act.

## Tests

```bash
pre-commit run --all-files --verbose      # terraform: fmt, validate, tflint, checkov
venv/bin/python -m pytest                 # 96 tests: helpers, spec invariants, transform
venv/bin/python -m pytest -m "not spark"  # 65 of them, no JVM needed, ~0.1s
```

No AWS credentials are needed for any of these. The Spark tests need a JVM and
skip automatically without one.

Set up the test environment with:

```bash
python3 -m venv venv
venv/bin/python -m pip install -r requirements-dev.txt
```

## Project structure

```
.
├── README.md               # this file
├── CLAUDE.md               # working rules and architecture notes for Claude Code
├── PROJECT_SCOPE.md        # architecture, decisions, open questions, build order
├── TODO.md                 # task tracker, by phase
├── AI_USAGE.md             # log of AI prompts and model outputs used to build this
├── docs/
│   └── data-layout.md      # S3 prefix layout and reprocessing semantics
├── glue/
│   └── jobs/
│       └── raw_to_processed.py
├── tests/                  # pytest: helpers, spec invariants, Spark transform
├── data/                   # sample source data
├── scripts/                # land_sample_data.sh
├── envs/
│   └── dev/                # dev environment root module
│       ├── backend.tf      # remote state; remove this file to go local
│       ├── main.tf         # locals
│       ├── kms.tf          # data lake encryption key
│       ├── storage.tf      # raw / processed / artifacts buckets
│       ├── glue.tf         # catalog databases, ETL job, crawler, schedule
│       └── iam.tf          # Glue job, crawler and scheduler roles
└── modules/
    └── s3_bucket/          # reusable private, encrypted bucket
```

## AI usage

This project was built with AI assistance. Every prompt issued and a record of
the corresponding model output is logged in [AI_USAGE.md](./AI_USAGE.md).
