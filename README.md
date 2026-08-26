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

Both data zones share one prefix layout — see [docs/data-layout.md](./docs/data-layout.md):

```
<source>/<dataset>/ingest_date=YYYY-MM-DD/<file>
```

## How this project is built

- **Terraform** defines all infrastructure. It is applied **manually** by a
  developer after reviewing the plan — there is no CI/CD deployment.
- **Commits are manual.**
- Components are built **one at a time**, in the phase order defined in the
  project scope. Each phase is applied and verified before the next begins.
- **State is local for now** (`envs/dev/terraform.tfstate`, gitignored) and must
  migrate to an S3 backend before Redshift lands — see D-32 and T-2.9.

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

```bash
RAW=$(terraform -chdir=envs/dev output -raw raw_bucket_name)

aws s3 cp ./customers_20260825.csv \
  "s3://$RAW/acme_crm/customers/ingest_date=2026-08-25/customers_20260825.csv"
```

### Running the ETL

The job processes one `ingest_date` partition per run. With no arguments it
picks the most recent partition present:

```bash
JOB=$(terraform -chdir=envs/dev output -raw glue_job_name)

aws glue start-job-run --job-name "$JOB"

# a specific date — reruns replace that partition rather than duplicating it
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

Because state is local, `terraform.tfstate` in `envs/dev/` is the **only** record
of what exists. Do not delete it, and do not run applies from two machines.

## Tests

```bash
pre-commit run --all-files --verbose      # fmt, validate, tflint, checkov
python3 -m py_compile glue/jobs/*.py      # job scripts parse
```

No AWS credentials are needed for any of these.

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
├── envs/
│   └── dev/                # dev environment root module (local state)
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
