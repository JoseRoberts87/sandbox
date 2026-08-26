# sandbox

A batch ETL pipeline and ML inference API on AWS, defined entirely in Terraform.

Raw data lands in **S3**, is transformed by **AWS Glue** ETL jobs, loaded into
**Amazon Redshift**, and used to train a model in **Amazon SageMaker**, which
serves predictions from an inference endpoint.

> **Status:** Phase 0 (Terraform foundations) and the raw S3 bucket are written
> and validated, but not yet applied. Architecture, decisions and build order
> are in [PROJECT_SCOPE.md](./PROJECT_SCOPE.md).

## Architecture

```
S3 (raw) ──Glue──► S3 (processed) ──COPY──► Redshift ──UNLOAD──► SageMaker ──► inference endpoint
   ▲
   └── built
```

## How this project is built

- **Terraform** defines all infrastructure. It is applied **manually** by a
  developer after reviewing the plan — there is no CI/CD deployment.
- **Commits are manual.**
- Components are built **one at a time**, in the phase order defined in the
  project scope. Each phase is applied and verified before the next begins.
- **State is local for now** (`envs/dev/terraform.tfstate`, gitignored) and
  migrates to an S3 backend later — see D-32.

## Requirements

| Tool | Version |
|---|---|
| Terraform | >= 1.9.0 (1.9.8 in use; >= 1.10 preferred before the state migration) |
| AWS CLI | v2 |
| AWS credentials | An account with permission to create S3 buckets and KMS keys |

## Setup

```bash
git clone <repo-url>
cd sandbox

# Authenticate to AWS
aws sso login --profile <your-profile>     # or export AWS_PROFILE / access keys
aws sts get-caller-identity                # confirm the target account
```

## Usage

```bash
cd envs/dev

terraform init      # first time, and after any module/provider change
terraform plan      # review before every apply
terraform apply     # manual, per D-07

terraform output    # bucket name, ARN, KMS key ARN
```

Upload a file to the raw bucket:

```bash
aws s3 cp ./data.csv \
  "s3://$(terraform -chdir=envs/dev output -raw raw_bucket_name)/<source>/<dataset>/ingest_date=$(date +%F)/data.csv"
```

Tear down:

```bash
cd envs/dev
# Buckets must be emptied first unless force_destroy_buckets = true
terraform destroy
```

Because state is local, `terraform.tfstate` in `envs/dev/` is the **only** record
of what exists. Do not delete it, and do not run applies from two machines.

## Tests

```bash
terraform fmt -recursive -check   # formatting
terraform validate                # from within envs/dev
```

## Project structure

```
.
├── README.md               # this file
├── PROJECT_SCOPE.md        # architecture, decisions, open questions, build order
├── AI_USAGE.md             # log of AI prompts and model outputs used to build this
├── envs/
│   └── dev/                # dev environment root module (local state)
└── modules/
    └── s3_bucket/          # reusable private, encrypted bucket
```

## AI usage

This project was built with AI assistance. Every prompt issued and a record of
the corresponding model output is logged in [AI_USAGE.md](./AI_USAGE.md).
