# Project Scope

An outline of what we are building, the decisions already made, the decisions
still open, and the order we will build in. **No implementation code yet** —
this document exists to get the shape of the system agreed on first.

Decision and question IDs (`D-##`, `Q-##`) are stable. Later documents and task
breakdowns should reference them rather than restating them.

---

## 1. What we are building

A batch ETL pipeline on AWS that lands raw data in S3, transforms it with Glue,
loads it into Redshift, trains a model in SageMaker, and serves predictions from
a SageMaker inference endpoint. All infrastructure is defined in Terraform and
applied manually by a developer.

### Data flow

```
  source data
      │
      ▼
┌─────────────┐   raw, immutable, as-landed
│  S3  (raw)  │
└─────────────┘
      │  Glue ETL job — validate, clean, conform, partition
      ▼
┌──────────────────┐   Parquet, partitioned
│ S3  (processed)  │◄──── Glue Data Catalog (schemas, partitions)
└──────────────────┘
      │  COPY
      ▼
┌─────────────┐   staging + analytics schemas
│  Redshift   │
└─────────────┘
      │  UNLOAD (training set)          ▲
      ▼                                 │ features
┌──────────────────┐                    │
│ S3  (artifacts)  │────► SageMaker training job
└──────────────────┘             │
                                 ▼
                        SageMaker Model Registry
                                 │  manual approval
                                 ▼
                        SageMaker inference endpoint
                                 │
                                 ▼
                            consumers
```

### Goals

- Reproducible: every piece of infrastructure is created by Terraform, not by
  hand in the console.
- Incremental: each layer works and is verifiable before the next one starts.
- Cheap at rest: an idle environment should cost close to nothing.
- Traceable: a prediction can be traced back to a model version, a training
  dataset, and the raw files it came from.

### Non-goals (explicitly out of scope for now)

- CI/CD. No pipeline runs `terraform apply`; no automated commits or releases.
- Streaming or near-real-time ingestion. This is batch.
- Multi-account or multi-region architecture.
- BI/dashboard layer on top of Redshift.
- Automated model retraining on a schedule, and automated promotion to production.
- A feature store.
- Fine-grained access control for end users (row-level security, data masking).

---

## 2. How we work

| Aspect | Approach |
|---|---|
| Infrastructure changes | Terraform, applied **manually** by a developer after reviewing the plan |
| Commits | **Manual**. No auto-commit, no auto-push |
| Build sequence | One component at a time, in the phase order in §7 |
| AI assistance | Every prompt and model output logged in [AI_USAGE.md](./AI_USAGE.md) |
| This document | Updated as decisions get made; open items move from §5 to §4 |

---

## 3. Components

### 3.1 S3 — raw and processed storage

Holds data at three stages plus supporting objects: raw (exactly as received,
never modified), processed (cleaned, conformed, Parquet), and artifacts (training
sets, model artifacts, Glue job scripts, logs).

Concerns to settle: bucket vs. prefix separation, partition layout, encryption
type, lifecycle and retention, versioning, how data arrives in the first place.

### 3.2 Glue — ETL

PySpark Glue jobs read raw, apply validation and transformation, and write
partitioned Parquet to the processed zone. The Glue Data Catalog holds table
definitions and partitions.

Concerns to settle: Glue version and worker sizing, catalog managed by crawler vs.
declared in Terraform, orchestration and triggering, incremental vs. full
reprocessing, where data-quality checks run and what happens when they fail.

### 3.3 Redshift — warehouse

Serving layer for the modelling dataset and for analytics. Landing schema for raw
loads, curated schema for the tables the model trains on.

Concerns to settle: Serverless vs. provisioned, load mechanism, schema design,
distribution and sort keys, credentials, network placement, how SageMaker reads
from it.

### 3.4 SageMaker — training and inference

A training job produces a model artifact, which is registered in the Model
Registry and deployed to an inference endpoint.

Concerns to settle: training approach and container, where feature engineering
lives, endpoint type, how the endpoint is exposed and authenticated, how a
retrained model reaches the endpoint.

### 3.5 Terraform — infrastructure as code

Every AWS resource above. Run from a developer machine with credentials for the
target account.

Concerns to settle: state backend and its bootstrap, repo/module layout,
environment separation, naming and tagging, provider/version pinning, and the
boundary between what Terraform owns and what runtime processes own.

---

## 4. Decisions already made

| ID | Decision |
|---|---|
| D-01 | Cloud provider is **AWS**. |
| D-02 | Raw data is stored in **S3**, unmodified from how it arrived. |
| D-03 | ETL is **AWS Glue**. Not EMR, not Lambda, not dbt-on-something-else. |
| D-04 | The warehouse is **Amazon Redshift**. |
| D-05 | ML training and the inference endpoint are **Amazon SageMaker**. |
| D-06 | All infrastructure is **Terraform**. No console click-ops, no CloudFormation, no CDK. |
| D-07 | `terraform apply` is run **manually by a developer**. No CI/CD deployment. |
| D-08 | Commits are **manual**. |
| D-09 | The pipeline is **batch**, not streaming. |
| D-10 | Components are built and verified **one at a time**, in phase order. |

---

## 5. Open decisions

Each has a recommendation. These are proposals to argue with, not conclusions.

### Storage

**D-11 — Bucket separation.** One bucket with `raw/`, `processed/`, `artifacts/`
prefixes, or separate buckets per zone?
*Recommendation:* separate buckets. Cleanest IAM boundary — a Glue job that reads
raw and writes processed should not have any grant that names the artifacts
bucket. Also allows per-zone lifecycle and replication rules without prefix
gymnastics.

**D-12 — Partition layout.** Proposal:
`s3://<proj>-<env>-raw/<source>/<dataset>/ingest_date=YYYY-MM-DD/<file>` and
`s3://<proj>-<env>-processed/<dataset>/<partition_key>=.../`.
The partition key for the processed zone should be whatever the ETL and Redshift
loads actually filter on — event date, not ingest date, if those differ.

**D-13 — Encryption.** SSE-S3 (free, AWS-managed) or SSE-KMS with a
customer-managed key (auditable, grantable, ~$1/month/key plus request charges)?
*Recommendation:* SSE-KMS with a CMK per environment. It is the difference between
"we can prove who could read this" and "we cannot", and it is cheap. Requires
adding `kms:Decrypt`/`kms:GenerateDataKey` to the Glue, Redshift, and SageMaker
roles — easy to forget, and the failure mode is a confusing AccessDenied.

**D-14 — Retention and lifecycle.** How long does raw data live before moving to
Glacier Instant Retrieval / Deep Archive, and does it ever expire?
*Recommendation:* raw never expires (it is the source of truth for reprocessing),
transitions to a colder class after 90 days. Processed data is regenerable, so
expire old partitions once reprocessing is proven. Versioning on for raw and
artifacts, off for processed.

**D-15 — How data lands in raw.** Manual upload, a vendor writing to our bucket,
a scheduled pull from an API/SFTP, or DMS from a source database?
This drives whether we need an ingestion component at all, and whether Glue is
triggered by a schedule or by object-created events. **Blocked on Q-01.**

### ETL

**D-16 — Catalog management.** Glue crawlers, or table definitions declared in
Terraform?
*Recommendation:* declare tables in Terraform for datasets with a known schema.
Crawlers are convenient but they infer types, change them silently between runs,
and put the schema outside version control. Keep a crawler available for
exploring new/unknown sources, but nothing production reads from a crawled table.

**D-17 — Orchestration.** Glue Workflows with triggers, Step Functions, or
EventBridge Scheduler firing a single job?
*Recommendation:* start with EventBridge Scheduler → one Glue job while there is
one job. Move to Step Functions when there is branching, fan-out, or a
cross-service sequence (Glue → Redshift COPY → SageMaker). Step Functions has
better failure visibility and retry semantics than Glue Workflows and is not much
more Terraform. Avoid MWAA — the cost floor is high for this workload.

**D-18 — Trigger mode.** Schedule (cron) vs. event-driven (S3 object created →
EventBridge → job)?
*Recommendation:* depends on D-15/Q-01. Files that arrive on a predictable
schedule → cron. Files that arrive whenever a vendor feels like it → event-driven,
with a debounce so 400 files do not start 400 job runs.

**D-19 — Incremental vs. full reprocessing.** Glue job bookmarks give us
incremental processing for free but make "reprocess last month" awkward.
*Recommendation:* bookmarks on for the normal path; every job also accepts an
explicit date-range parameter that bypasses bookmarks for backfills. Writes are
idempotent per partition (overwrite the partition, do not append) so a rerun
cannot double-count.

**D-20 — Data quality.** AWS Glue Data Quality rulesets, assertions written into
the job, or an external framework?
*Recommendation:* Glue Data Quality — native, no extra infrastructure, results
land in CloudWatch. Needs a policy decision: does a failed rule **stop** the load
(no bad data in Redshift, pipeline halts) or **warn** (data flows, alarm fires)?
Proposal: fail closed on schema/uniqueness/null-key violations, warn on
distribution drift.

**D-21 — Language and structure of job code.** PySpark scripts in the repo,
uploaded to the scripts bucket. Glue Studio's visual editor produces code we
cannot review in a diff, so it is out. Python shell jobs are an option for small
datasets where Spark is overkill — worth checking once we know data volume (Q-05).

### Warehouse

**D-22 — Redshift Serverless vs. provisioned.**
*Recommendation:* **Serverless.** It scales to zero between batch runs, which is
most of the time for this workload, and it removes cluster sizing from the list of
things we have to get right up front. Provisioned RA3 becomes cheaper only at
sustained high utilization; we can move later if the bill says so. Note Serverless
needs subnets in at least three availability zones.

**D-23 — Load mechanism.** Glue writing to Redshift directly over JDBC, or Glue
writing Parquet to S3 and Redshift `COPY`-ing it?
*Recommendation:* **write to S3, then COPY.** JDBC writes from Spark are slow,
hold connections open, and put the warehouse in the failure path of the ETL job.
COPY is parallel, restartable, and leaves the processed Parquet as an artifact we
can re-load or query with Spectrum. Open sub-question: who issues the COPY — the
Glue job at the end of its run, or a separate step in the orchestrator? A separate
step is easier to retry.

**D-24 — Schema design.** Proposal: `landing` schema (COPY target, mirrors the
processed files), `analytics` schema (curated, modelled tables), `ml` schema (the
exact training views/tables SageMaker reads). Keeping the ML dataset as its own
versioned object matters for reproducibility — "which rows did model v3 train on"
should be answerable.

**D-25 — Credentials.** AWS-managed admin credentials stored in Secrets Manager,
so no password is ever written to Terraform state in plaintext. Component access
uses IAM roles rather than passwords wherever the service supports it.

**D-26 — How SageMaker reads Redshift.** Redshift Data API (IAM-authenticated,
no VPC connectivity required) or a JDBC connection from inside the VPC?
*Recommendation:* Data API to issue an `UNLOAD` to S3, then train from S3. Avoids
putting the training job in the VPC, avoids a NAT gateway, and the UNLOADed
snapshot is exactly the reproducible training artifact D-24 asks for.

### ML

**D-27 — Where feature engineering lives.** In Glue/Redshift (features are columns
in the warehouse), or in the model container (raw fields in, features computed at
both training and inference time)?
This is the single most consequential decision in the ML half. Splitting it across
both places is how training/serving skew happens. *Recommendation:* aggregate and
historical features are computed in the warehouse; only row-local transforms
(scaling, encoding) live in the model artifact, packaged with the model so
training and inference use the identical code path. **Depends on Q-02/Q-03.**

**D-28 — Training approach.** SageMaker built-in algorithm, script mode in a
managed container, or a custom container?
*Recommendation:* script mode with a managed framework container (XGBoost or
scikit-learn). Our code, their runtime — no image build to maintain, and no
lock-in to a built-in algorithm's input format. Revisit if the problem turns out to
need something the managed images do not cover.

**D-29 — Endpoint type.** Real-time (always-on instance), Serverless Inference
(scales to zero, cold starts, CPU-only, memory-capped), or Asynchronous?
*Recommendation:* Serverless Inference for development and low/bursty traffic;
switch to provisioned real-time if a latency SLO makes cold starts unacceptable.
**Depends on Q-03.**

**D-30 — Endpoint exposure and auth.** A SageMaker endpoint is not publicly
callable — every request must be SigV4-signed with IAM credentials. So: do
consumers assume an IAM role and call `InvokeEndpoint` directly, or do we front it
with API Gateway (+ a Lambda proxy) for API keys, throttling, and request/response
shaping?
*Recommendation:* if consumers are AWS workloads in our account, direct IAM invoke
— fewer moving parts. If anything outside the account calls it, API Gateway.
**Depends on Q-04.**

**D-31 — Retraining and promotion.** Terraform pinning the endpoint to a specific
model artifact means every retrain is a `terraform apply` — which keeps the
deployed model version in version control, but couples model releases to
infrastructure releases.
*Recommendation:* Terraform owns the endpoint and its scaling configuration;
training runs register new versions in the Model Registry; promotion is a
deliberate, manual step consistent with D-07. Which of the two mechanisms performs
the swap is worth deciding explicitly rather than by accident.

### Terraform and platform

**D-32 — State backend.** **Decided: start with local state, migrate to S3
later.** Local state avoids the bootstrap problem entirely for the first deploy
— the state bucket cannot manage its own creation — and keeps the first apply to
a single command. The commented backend block in `envs/dev/versions.tf` holds the
migration path (`terraform init -migrate-state`).

Two things to settle before migrating: native S3 lockfiles (`use_lockfile`)
require Terraform >= 1.10 and the installed version is 1.9.8, so migrating today
means a DynamoDB lock table that we would later remove — upgrading Terraform
first is the cheaper order. And local state must not outlive Phase 3: the moment
Redshift exists, state contains sensitive values and a laptop is the wrong place
for the only copy. Migrate at the end of Phase 2 at the latest.

**D-33 — Version pinning.** Pin `required_version` for Terraform and a `~>`
constraint on the AWS provider, with `.terraform.lock.hcl` committed. Manual
applies from developer machines make version drift between developers a real
failure mode.

**D-34 — Repo and module layout.** Root configurations per environment
(`envs/dev`, `envs/prod`) calling shared `modules/` — or a single root with
workspaces?
*Recommendation:* directories over workspaces. Workspaces share one configuration,
so environments cannot diverge (dev on tiny instances, prod on real ones) without
conditionals everywhere. Directories make "what is actually deployed in dev"
readable.

**D-35 — Environments.** Start with `dev` only, in a single account. Add `prod`
once the shape is stable. Decide now whether prod is a separate AWS account (Q-06);
retrofitting account separation later is significantly more work than starting
with it.

**D-36 — Naming and tagging.** `<project>-<env>-<component>` for resource names,
with provider-level default tags (`Project`, `Environment`, `ManagedBy=terraform`,
`Owner`, `CostCenter`). Tags are how we will answer "what is this line item on the
bill".

**D-37 — Networking.** Redshift Serverless requires a VPC. Does anything else?
*Recommendation:* private subnets across three AZs, an S3 gateway endpoint (free),
and **no NAT gateway** unless something proves it needs one — a NAT gateway is a
constant hourly charge in an environment designed to idle at near-zero. Prefer
interface endpoints for the specific services that need them.

**D-38 — Terraform's boundary.** Terraform owns infrastructure. It does **not**
own: data in S3, rows in Redshift, model artifacts, or in-flight job runs. Two
grey areas to settle deliberately — Glue job *scripts* (Terraform-uploaded, so the
deployed script matches the commit? or synced separately?) and Redshift *schema
DDL* (Terraform has no good story for this; a migration tool or a versioned SQL
directory applied manually is the usual answer).

**D-39 — Cost guardrails.** An AWS Budget with an alarm at a threshold set from
Q-07, S3 lifecycle rules, Redshift Serverless auto-pause, Serverless Inference,
and a documented teardown procedure for the dev environment.

**D-40 — Observability.** CloudWatch log groups with explicit retention (the
default is "forever", which quietly accrues cost), alarms on Glue job failure,
COPY failure, and endpoint 5xx/latency, delivered to an SNS topic with an email
subscription. Decide whether a failed nightly run should page someone or wait for
business hours.

---

## 6. Questions we need answered

These block specific decisions. They are about the problem, not the technology.

| ID | Question | Blocks |
|---|---|---|
| Q-01 | What is the data source, what format does it arrive in, and how does it get to S3? | D-15, D-18 |
| Q-02 | What is the ML problem — what are we predicting, from what, and is it classification or regression? | D-27, D-28 |
| Q-03 | Latency and throughput requirements for the endpoint — is a cold start of several seconds acceptable? | D-27, D-29 |
| Q-04 | Who calls the endpoint? Our own AWS workloads, an internal service outside AWS, or external customers? | D-30 |
| Q-05 | Data volume — per batch and total — and how fast is it growing? | D-21, D-22 |
| Q-06 | Which AWS account and region, and is prod a separate account? | D-35, D-37 |
| Q-07 | Monthly budget ceiling. | D-39 |
| Q-08 | How fresh must the data be — daily, hourly, or "whenever it arrives"? | D-17, D-18 |
| Q-09 | Any compliance constraints on the data (PII, retention obligations, residency)? | D-13, D-14 |

---

## 7. Build order

Each phase ends with something demonstrably working. Nothing in a later phase
starts before the previous phase is applied and verified.

| Phase | Deliverable | Done when |
|---|---|---|
| **0. Foundations** | Terraform bootstrap: state backend, provider config, naming/tagging conventions, base IAM, repo layout | `terraform apply` succeeds against an empty account and state is remote |
| **1. Storage** | S3 buckets, encryption, lifecycle, block-public-access, partition layout documented | A sample raw file is landed and readable only by the intended roles |
| **2. ETL** | Glue job(s), Data Catalog tables, orchestration/trigger, data quality rules | Raw sample → partitioned Parquet in processed, catalog queryable in Athena |
| **3. Warehouse** | Redshift Serverless, network placement, schemas, COPY path | Processed data lands in `landing` and is queryable in `analytics` |
| **4. Training** | UNLOAD to a versioned training set, SageMaker training job, Model Registry | A model artifact exists and is traceable to its training data |
| **5. Inference** | Endpoint, model deployment, front door and auth per D-30 | A prediction request returns a correct response end to end |
| **6. Hardening** | Alarms, budget, log retention, runbooks, teardown procedure | A deliberately failed job produces an alert; teardown leaves no billable resources |

Detailed task breakdowns for each phase come later, one phase at a time.

**Current status (2026-08-25):** Phase 0 and the raw bucket from Phase 1 are
written and validated (`terraform validate` passes, provider resolved and
locked), but **not yet applied** — pending AWS credentials and confirmation of
Q-06 (account/region). Decisions realised in code so far: D-11 (module reusable
per zone), D-13 (customer-managed KMS key), D-14 (versioned, 90-day cold
transition, no expiry), D-32 (local state), D-33 (version pinning +
`.terraform.lock.hcl` committed), D-34 (`envs/` + `modules/` layout), D-36
(naming prefix + `default_tags`).

---

## 8. Known risks

| Risk | Why it matters | Mitigation |
|---|---|---|
| Training/serving skew | The model performs well offline and badly in production, and it is hard to diagnose | Settle D-27 before writing any transform code; share one code path |
| Cost drift from idle resources | NAT gateways, provisioned Redshift, and always-on endpoints bill 24/7 in an environment used minutes per day | D-22, D-29, D-37, D-39; check the bill after each phase |
| Terraform state loss or corruption | Manual applies from developer machines with no CI to serialize them | D-32 (remote state + locking), bootstrap applied once, state bucket versioned |
| Schema drift in source data | A silently changed upstream column corrupts the warehouse and the model's inputs | D-16 (declared schemas), D-20 (fail closed on schema violations) |
| Redshift as a single point of coupling | ETL, training, and analytics all depend on it | D-23 (S3 stays the durable intermediate; Redshift is rebuildable from processed Parquet) |
| Manual promotion becomes a bottleneck | Every model update needs a human and possibly a `terraform apply` | Accepted for now — D-07 makes this deliberate. Revisit if retraining becomes frequent |

---

## 9. Changelog

| Date | Change |
|---|---|
| 2026-08-25 | Initial scope. Architecture, D-01–D-40, Q-01–Q-09, seven-phase build order. |
| 2026-08-25 | D-32 decided: local state first, migrate to S3 remote state later. Phase 0 + raw bucket implemented. |
