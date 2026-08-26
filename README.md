# sandbox

A batch ETL pipeline and ML inference API on AWS, defined entirely in Terraform.

Raw data lands in **S3**, is transformed by **AWS Glue** ETL jobs, loaded into
**Amazon Redshift**, and used to train a model in **Amazon SageMaker**, which
serves predictions from an inference endpoint.

> **Status: planning.** No implementation code yet. The architecture, decisions,
> and build order are in [PROJECT_SCOPE.md](./PROJECT_SCOPE.md).

## Architecture

```
S3 (raw) ──Glue──► S3 (processed) ──COPY──► Redshift ──UNLOAD──► SageMaker ──► inference endpoint
```

## How this project is built

- **Terraform** defines all infrastructure. It is applied **manually** by a
  developer after reviewing the plan — there is no CI/CD deployment.
- **Commits are manual.**
- Components are built **one at a time**, in the phase order defined in the
  project scope. Each phase is applied and verified before the next begins.

## Requirements

<!-- TODO: Terraform version, AWS CLI, Python version, AWS account/region -->

## Setup

```bash
git clone <repo-url>
cd sandbox
# TODO: bootstrap the Terraform state backend, then configure the dev environment
```

## Usage

```bash
# TODO: terraform plan / apply workflow, running an ETL job, invoking the endpoint
```

## Tests

```bash
# TODO
```

## Project structure

```
.
├── README.md          # this file
├── PROJECT_SCOPE.md   # architecture, decisions, open questions, build order
└── AI_USAGE.md        # log of AI prompts and model outputs used to build this
```

## AI usage

This project was built with AI assistance. Every prompt issued and a record of
the corresponding model output is logged in [AI_USAGE.md](./AI_USAGE.md).
