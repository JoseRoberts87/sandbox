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

**Decided (2026-08-25):** three buckets — `raw`, `processed`, `artifacts`. Implemented.

**D-12 — Partition layout.** Proposal:
`s3://<proj>-<env>-raw/<source>/<dataset>/ingest_date=YYYY-MM-DD/<file>` and
`s3://<proj>-<env>-processed/<dataset>/<partition_key>=.../`.
The partition key for the processed zone should be whatever the ETL and Redshift
loads actually filter on — event date, not ingest date, if those differ.

**Revised (2026-08-27): the zones are asymmetric.**

```
raw        <source>/<dataset>/<file>
processed  <source>/<dataset>/ingest_date=YYYY-MM-DD/*.parquet
```

Raw is flat. It holds one small, whole dataset that arrives as a single file, and
partitioning it by arrival date added a path segment that carried no information
— every partition would have held the same file. A run now reads the entire
dataset prefix.

Processed keeps `ingest_date`, which is the date of the **run**. Each partition
is therefore a complete snapshot of raw at that moment, which has one consequence
worth stating plainly: **consumers must read the newest partition, not all of
them**, or every row is counted once per run. Rerunning a date still purges and
rewrites that partition, so idempotency is unaffected.

Two things this leaves open. If a real feed later delivers dated drops, raw
should be partitioned again (Q-01). And once the data is queried in anger,
partitioning processed on `order_date` — already derived — would suit real
queries better and make partitions additive rather than repeated; worth settling
before the phase 3 COPY, since it changes what Redshift should read.

Documented in [docs/data-layout.md](./docs/data-layout.md).

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

**Decided (2026-08-26), with a caveat:** an on-demand crawler exists for the raw zone, exploration only, and nothing downstream reads from it. The *processed* table is currently created by the job's catalog sink rather than declared in Terraform, because we do not yet know the schema to declare. That is a deliberate temporary deviation: **T-2.10** moves the processed table into Terraform once the schema is fixed, and flips `--update_catalog` to `false`.

**D-17 — Orchestration.** Glue Workflows with triggers, Step Functions, or
EventBridge Scheduler firing a single job?
*Recommendation:* start with EventBridge Scheduler → one Glue job while there is
one job. Move to Step Functions when there is branching, fan-out, or a
cross-service sequence (Glue → Redshift COPY → SageMaker). Step Functions has
better failure visibility and retry semantics than Glue Workflows and is not much
more Terraform. Avoid MWAA — the cost floor is high for this workload.

**Decided (2026-08-26):** EventBridge Scheduler firing a single Glue job. Revisit when a second step exists — the Redshift COPY in phase 3 is the likely trigger for moving to Step Functions.

**D-18 — Trigger mode.** Schedule (cron) vs. event-driven (S3 object created →
EventBridge → job)?
*Recommendation:* depends on D-15/Q-01. Files that arrive on a predictable
schedule → cron. Files that arrive whenever a vendor feels like it → event-driven,
with a debounce so 400 files do not start 400 job runs.

**Decided (2026-08-26):** scheduled (cron), daily at 06:00 UTC, **created disabled**. Nothing fires until there is real data and an answer to Q-08.

**D-19 — Incremental vs. full reprocessing.** Glue job bookmarks give us
incremental processing for free but make "reprocess last month" awkward.
*Recommendation:* bookmarks on for the normal path; every job also accepts an
explicit date-range parameter that bypasses bookmarks for backfills. Writes are
idempotent per partition (overwrite the partition, do not append) so a rerun
cannot double-count.

**Revised (2026-08-26): bookmarks are off.** The layout already partitions raw by `ingest_date`, so a run is addressed by a date and the job purges the target partition before rewriting it. That makes reruns idempotent and a backfill the identical code path with a different `--ingest_date`. Bookmarks would add service-side progress state that can drift from what is actually in S3, and would make backfills a special case. The trade-off: a file that lands late into an already-processed partition is not picked up automatically — that date must be rerun. Acceptable while cadence is daily and volumes are small; revisit if late-arriving data becomes normal.

**D-20 — Data quality.** AWS Glue Data Quality rulesets, assertions written into
the job, or an external framework?
*Recommendation:* Glue Data Quality — native, no extra infrastructure, results
land in CloudWatch. Needs a policy decision: does a failed rule **stop** the load
(no bad data in Redshift, pipeline halts) or **warn** (data flows, alarm fires)?
Proposal: fail closed on schema/uniqueness/null-key violations, warn on
distribution drift.

**Extended (2026-08-26).** Three tiers, not one:

- **Structural problems fail the run immediately** — a missing column, an unreadable path, an empty partition. These mean the file is not what we think it is, and loading any of it would be wrong.
- **Row-level problems are quarantined, not dropped.** A row that fails to parse or violates a constraint is written to `_rejected/<source>/<dataset>/ingest_date=.../` with its original values and a `reject_reason`. Silently nulling a bad value is the failure mode this exists to prevent.
- **The run fails if the reject rate exceeds `--max_reject_pct` (default 5%).** A few bad rows should not kill a batch; a feed that has broken should not load quietly. Rejects are written before the threshold is evaluated, so a failed run still leaves the evidence.

Formal Glue Data Quality rulesets still need a catalog table to target — T-2.17.

**D-21 — Language and structure of job code.** PySpark scripts in the repo,
uploaded to the scripts bucket. Glue Studio's visual editor produces code we
cannot review in a diff, so it is out. Python shell jobs are an option for small
datasets where Spark is overkill — worth checking once we know data volume (Q-05).

**Decided (2026-08-26):** PySpark scripts under `glue/jobs/`, reviewed in diffs like any other code. Glue 5.0, `G.1X`, 2 workers to start — revisit against real volume (Q-05).

### Warehouse

**D-22 — Redshift Serverless vs. provisioned.**
*Recommendation:* **Serverless.** It scales to zero between batch runs, which is
most of the time for this workload, and it removes cluster sizing from the list of
things we have to get right up front. Provisioned RA3 becomes cheaper only at
sustained high utilization; we can move later if the bill says so. Note Serverless
needs subnets in at least three availability zones.

**Decided (2026-08-27):** Redshift Serverless, 8 RPU base (the floor), 32 RPU max, plus an `aws_redshiftserverless_usage_limit` of 40 RPU-hours/month with `breach_action = deactivate`. This is the first component that can run up a bill on its own and there is no budget alarm yet (T-6.3), so the limit is a hard stop rather than a warning. It will look like an outage if it fires — that is the intended trade.

**D-23 — Load mechanism.** Glue writing to Redshift directly over JDBC, or Glue
writing Parquet to S3 and Redshift `COPY`-ing it?
*Recommendation:* **write to S3, then COPY.** JDBC writes from Spark are slow,
hold connections open, and put the warehouse in the failure path of the ETL job.
COPY is parallel, restartable, and leaves the processed Parquet as an artifact we
can re-load or query with Spectrum. Open sub-question: who issues the COPY — the
Glue job at the end of its run, or a separate step in the orchestrator? A separate
step is easier to retry.

**Revised (2026-08-27): loading through Spectrum, not COPY.** `COPY` cannot populate a partition column, and `ingest_date` exists only as an S3 path segment — so a COPY-based load would need a staging table and a literal date injected per run. A Spectrum external schema over the Glue catalog the ETL already maintains exposes `ingest_date` as a real column, which makes the load a plain `DELETE` + `INSERT ... SELECT` on one partition: idempotent, and mirroring exactly how the ETL rewrites that partition in S3. The substance of the original decision stands — data moves S3 → warehouse, never over Spark JDBC — and the processed Parquet is still the durable intermediate.

**D-24 — Schema design.** Proposal: `landing` schema (COPY target, mirrors the
processed files), `analytics` schema (curated, modelled tables), `ml` schema (the
exact training views/tables SageMaker reads). Keeping the ML dataset as its own
versioned object matters for reproducibility — "which rows did model v3 train on"
should be answerable.

**Decided (2026-08-27):** `landing` (mirrors the processed Parquet), `analytics` (curated), `ml` (empty until Q-02). The one that matters: `analytics.orders` is a view pinned to `MAX(ingest_date)`. Since every partition is a full snapshot (D-12), querying `landing.orders` directly counts each order once per run — the view is the safe entry point, and the table is the history.

**D-25 — Credentials.** AWS-managed admin credentials stored in Secrets Manager,
so no password is ever written to Terraform state in plaintext. Component access
uses IAM roles rather than passwords wherever the service supports it.

**Decided (2026-08-27):** `manage_admin_password = true` on the namespace, so AWS generates and holds the credential in Secrets Manager and no password is ever written to Terraform state. The Data API authenticates with the secret ARN.

**D-26 — How SageMaker reads Redshift.** Redshift Data API (IAM-authenticated,
no VPC connectivity required) or a JDBC connection from inside the VPC?
*Recommendation:* Data API to issue an `UNLOAD` to S3, then train from S3. Avoids
putting the training job in the VPC, avoids a NAT gateway, and the UNLOADed
snapshot is exactly the reproducible training artifact D-24 asks for.

**Decided (2026-08-27):** `UNLOAD` through the Data API to a versioned prefix, `s3://<artifacts>/training/<version>/`. SageMaker trains from those files, so it needs no VPC attachment and no NAT — and the UNLOADed snapshot *is* the reproducible artifact, which is what makes "which rows did this model learn from" answerable.

### ML

**D-27 — Where feature engineering lives.** In Glue/Redshift (features are columns
in the warehouse), or in the model container (raw fields in, features computed at
both training and inference time)?
This is the single most consequential decision in the ML half. Splitting it across
both places is how training/serving skew happens. *Recommendation:* aggregate and
historical features are computed in the warehouse; only row-local transforms
(scaling, encoding) live in the model artifact, packaged with the model so
training and inference use the identical code path. **Depends on Q-02/Q-03.**

**Decided (2026-08-27).** The split runs along one line: **row selection and labelling in the warehouse, row-local transforms in the model artifact.**

`ml.orders_training` (SQL, reviewable in a diff) chooses the rows, defines the label, and excludes leakage. The model artifact is a single sklearn `Pipeline` containing imputation, encoding, scaling *and* the classifier — so inference physically cannot apply different preprocessing from training, because there is one object and one code path. Splitting them is how training/serving skew happens, and it looks fine offline.

Leakage exclusions are documented in the view rather than inferred: `shipping_days` is unknown at scoring time; `pending` orders are excluded because they have not resolved, and at scoring time every new order is pending; the hour of `order_ts` is excluded because 7 of 19 source rows carry a date with no time, so hour would encode which timestamp format the row arrived in — a property of our ETL, not of the order.

**D-28 — Training approach.** SageMaker built-in algorithm, script mode in a
managed container, or a custom container?
*Recommendation:* script mode with a managed framework container (XGBoost or
scikit-learn). Our code, their runtime — no image build to maintain, and no
lock-in to a built-in algorithm's input format. Revisit if the problem turns out to
need something the managed images do not cover.

**Decided (2026-08-27):** script mode on the managed scikit-learn container, with a `LogisticRegression` pipeline. Our code, their runtime — no image to build or maintain. The model choice is close to irrelevant at this data size; the pipeline shape is the deliverable.

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

**Partially decided (2026-08-27):** training runs register a version in the Model Registry as `PendingManualApproval`, and `terraform apply` is not involved — a retrain is a script, not an infrastructure change. What performs the endpoint swap on approval is still open, and lands with phase 5.

### Terraform and platform

**D-32 — State backend.** **Done (2026-08-27): state is in S3.**

```
bucket  joseroberts87-tf-backend-etl
key     envs/dev/terraform.tfstate
lock    S3-native conditional writes (use_lockfile) — no DynamoDB table
```

Local state got us through phases 0–2 without the bootstrap problem — the state
bucket cannot manage its own creation — and remote state arrived before Redshift,
which was the deadline that mattered: from phase 3 on, state contains secrets and
a laptop is the wrong place for the only copy.

The Terraform upgrade (T-0.10) paid off here: `use_lockfile` needs >= 1.10, so
there is no DynamoDB lock table to create now or remove later.

The bucket is created by hand and is deliberately outside Terraform's ownership.
It must have versioning enabled — that is the only recovery path from a corrupted
state write.

Local state remains supported for throwaway work: `envs/dev/backend.tf` holds the
backend on its own, so removing the file and re-initialising switches modes. The
README documents both directions.

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

**Decided (2026-08-27):** a VPC that exists only because Redshift Serverless demands one — three private subnets, an S3 gateway endpoint, **no internet gateway and no NAT**, and a security group with no ingress whatsoever (the Data API is an AWS API call, not VPC traffic). Egress is restricted to the S3 prefix list. `enhanced_vpc_routing` is on, so S3 traffic uses the endpoint; it is behind a variable because it is the first thing to suspect if a load fails with an opaque S3 or KMS timeout.

**D-38 — Terraform's boundary.** Terraform owns infrastructure. It does **not**
own: data in S3, rows in Redshift, model artifacts, or in-flight job runs. Two
grey areas to settle deliberately — Glue job *scripts* (Terraform-uploaded, so the
deployed script matches the commit? or synced separately?) and Redshift *schema
DDL* (Terraform has no good story for this; a migration tool or a versioned SQL
directory applied manually is the usual answer).

**Decided for Glue scripts (2026-08-26):** Terraform uploads them (`aws_s3_object` with `source_hash`, not `etag` — KMS-encrypted objects have no MD5 etag), so the deployed script always matches the commit. Redshift DDL is still open.

**Decided for Redshift DDL (2026-08-27):** ordered, re-runnable files in `sql/migrations/`, applied by `scripts/redshift_sql.sh` through the Data API. Terraform does not run them — it owns infrastructure, not schema. Placeholders are filled from terraform outputs, and a file naming one with no value fails rather than substituting an empty string.

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
| Q-01 | ~~What format does the data arrive in?~~ **Partially answered:** CSV with header, 13 columns, profiled in [docs/dataset-takehome-orders.md](./docs/dataset-takehome-orders.md). Still open: what system produces it, and how it will reach S3 in future (manual upload for now) | D-15, D-18 |
| Q-02 | ~~What is the ML problem?~~ **Answered (2026-08-27):** binary classification — will an order end up refunded, from information available when it is placed. Defined in `sql/migrations/005_ml_training_view.sql` | D-27, D-28 |
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
Live progress against these phases is tracked in [TODO.md](./TODO.md).

**Current status (2026-08-27):** Phases 0–2 are applied, but **phase 2 has never
completed a run** — the first attempt failed at startup and the fix is not yet
applied (T-2.12). Phases 3 and 4 are written and validated but not applied:
VPC, Redshift Serverless, schema migrations, the load path, the SageMaker
execution role, the Model Registry group and the training workflow.

Both were built ahead of the verification rule at the top of §7, and the
dependency chain is real: the warehouse load reads the Glue catalog table the
ETL registers, and training reads the warehouse. Nothing downstream of T-2.12
can be exercised until the Glue job completes a run. The training script itself
*has* been verified end to end locally, against the real sample file through the
actual Spark transform.

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
| 2026-08-25 | Added `TODO.md` — phase-by-phase task tracker keyed to these decisions. |
| 2026-08-26 | Phase 2 (ETL) built. D-11, D-12, D-17, D-18, D-21, D-38 decided; D-16 and D-20 partially decided pending schema; **D-19 revised** — bookmarks off, in favour of date-addressed idempotent partition rewrites. |
| 2026-08-26 | `pre-commit` added (fmt, validate, tflint, checkov). Two real findings fixed — Glue security configuration and a CMK on the ETL schedule. Two documented skips: one verified false positive, one deferred to T-6.6. |
| 2026-08-26 | Real dataset arrived. `takehome/orders` schema and cleaning rules declared in the job; `inferSchema` demoted to a fallback. D-20 extended: row-level failures are quarantined to `_rejected/` with a reason and a reject-rate threshold, rather than failing the batch. Q-01 partially answered. |
| 2026-08-26 | pytest suite added (96 tests). It caught two implicit runtime dependencies in the job: ANSI mode (a failed cast throws rather than nulling, which would abort a batch and defeat quarantine entirely) and session timezone (date bucketing able to shift a day). Both are now set explicitly in `configure_session()`. |
| 2026-08-27 | D-12 revised: raw is flat (`<source>/<dataset>/<file>`), processed stays partitioned by `ingest_date` = the run date. Processed partitions are now full snapshots, so consumers read the newest one. `--ingest_date` defaults to `today`; `latest` now resolves against processed, to redo the most recent load. |
| 2026-08-27 | D-32 closed: state migrated to S3 (`joseroberts87-tf-backend-etl`) with S3-native locking, no DynamoDB. Backend isolated in `backend.tf` so local state stays available for throwaway work. |
| 2026-08-27 | Phase 3 built: VPC (3 AZs, no NAT), Redshift Serverless with a usage limit, IAM, `sql/` migrations and a Data API runner. D-22, D-24, D-25, D-37 decided; D-38's Redshift half decided; **D-23 revised** — Spectrum + `INSERT ... SELECT` instead of `COPY`, because COPY cannot populate a partition column. |
| 2026-08-27 | Phase 4 built. **Q-02 answered** — refund-risk classification. D-26, D-27, D-28 decided; D-31 partially. Training verified end to end locally against the real sample data through the actual Spark transform. |
