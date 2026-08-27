# TODO

Progress tracker. Phases mirror [PROJECT_SCOPE.md §7](./PROJECT_SCOPE.md); `D-##`
and `Q-##` refer to the decisions and open questions in that document.

**Task IDs (`T-<phase>.<n>`) are stable.** Add new tasks with the next free
number in the phase — do not renumber, since notes and commits reference them.

| Marker | Meaning |
|---|---|
| `- [ ]` | Not started |
| `- [x]` | Done |
| 🔴 | Blocked — see the reason inline |
| 🔵 | In progress |

Later phases are deliberately coarse. Each gets expanded into real tasks when
its turn comes, not before.

---

## Now — the next three things

1. **T-2.11** — apply phase 2 (buckets, Glue catalog, job, role, disabled schedule).
2. **T-1.10 / T-2.12** — land `data/dpe_interview_takehome_data.csv` in raw and
   run the job end to end. The transform rules are verified against the file, but
   the job itself has never executed.
3. **T-2.14 / T-2.10** — confirm idempotency on a rerun, then declare the
   processed table in Terraform now that the schema is known.

## Blocked

| Task | Waiting on |
|---|---|
| T-2.10 (Terraform half), T-2.17 | A processed table confirmed by a real run (T-2.12) |
| T-2.6 (arming the schedule) | **Q-08** — batch cadence — and real data to run against |
| T-1.9 | A few days of billing history after the phase 2 apply |

---

## Phase 0 — Foundations

- [x] **T-0.1** Repo layout: `envs/` roots + shared `modules/` (D-34)
- [x] **T-0.2** `.gitignore` covering state, plan files, and provider cache
- [x] **T-0.3** Pin `required_version` and AWS provider `~> 6.61`; commit `.terraform.lock.hcl` (D-33)
- [x] **T-0.4** Provider `default_tags` and the `<project>-<env>-<component>` naming convention (D-36)
- [x] **T-0.5** Local state, with the S3 backend block written, commented, and annotated with migration steps (D-32)
- [x] **T-0.6** `terraform fmt` / `init` / `validate` all pass
- [x] **T-0.7** Initial git commit
- [x] 🔴 **T-0.8** Confirm AWS account, region, and `project` name — update `terraform.tfvars` (Q-06)
- [x] 🔴 **T-0.9** First clean `terraform plan` against the real account
- [x] **T-0.10** Upgrade Terraform to >= 1.10 — lets the state migration use native S3 lockfiles instead of a throwaway DynamoDB table (D-32). Do before T-2.9.

## Phase 1 — Storage

- [x] **T-1.1** Reusable `s3_bucket` module: public access block, ACLs disabled, versioning, default encryption, lifecycle rules, TLS-only bucket policy
- [x] **T-1.2** Raw bucket defined — versioned, 90-day cold transition, no expiry (D-02, D-14)
- [x] **T-1.3** Customer-managed KMS key with rotation, plus alias (D-13)
- [x] **T-1.4** Apply, and confirm the bucket exists with the expected name
- [x] **T-1.5** Verify posture end to end: upload a test object, confirm it is KMS-encrypted, confirm a non-TLS request is denied, confirm the bucket is not publicly readable
- [x] **T-1.6** Verify the lifecycle rules are attached as expected
- [x] **T-1.7** Prefix layout settled as `<source>/<dataset>/ingest_date=YYYY-MM-DD/` and documented in [docs/data-layout.md](./docs/data-layout.md) (D-12)
- [x] **T-1.8** Processed and artifacts buckets created now, alongside the ETL that writes to them (D-11)
- [ ] **T-1.9** Check the bill after a few days — confirm an idle environment costs roughly the KMS key and nothing else
- [ ] **T-1.10** Land `data/dpe_interview_takehome_data.csv` in raw at `takehome/orders/ingest_date=2026-08-26/`

## Phase 2 — ETL

- [x] **T-2.1** Catalog management decided: crawler for raw-zone exploration only; processed table written by the job's sink until the schema is known (D-16)
- [x] **T-2.2** Processed bucket, plus the artifacts bucket for scripts, Glue temp and Spark logs
- [x] **T-2.3** Glue job execution role — explicit least-privilege statements, raw read-only, including KMS on the S3 key
- [x] **T-2.4** `glue/jobs/raw_to_processed.py` — read one `ingest_date` partition, normalize columns, validate, stamp lineage, write Parquet
- [x] **T-2.5** Script delivery: Terraform uploads it with `source_hash`, so the deployed script matches the commit (D-38)
- [x] **T-2.6** EventBridge Scheduler → Glue job, **created disabled** until Q-08 (D-17, D-18)
- [x] **T-2.7** Idempotent reruns by purge-then-write per partition; bookmarks off (revision to D-19)
- [x] **T-2.8** Row-level validation with quarantine: bad rows go to `_rejected/` with a reason, and the run fails above `--max_reject_pct`. Formal Glue Data Quality rulesets still need a catalog table
- [ ] **T-2.17** 🔴 Glue Data Quality rulesets — in-job fail-closed checks exist (empty partition, missing required columns); formal rulesets need a catalog table
- [ ] **T-2.11** Apply phase 2 and confirm the job, role, databases and crawler exist
- [ ] **T-2.12** Land a sample file and run the job end to end; confirm Parquet lands in the right partition and the catalog table appears
- [ ] **T-2.13** Run the raw crawler to discover the real schema (unblocks Q-01, Q-02, T-2.10)
- [ ] **T-2.14** Verify idempotency for real: run the same date twice, confirm the row count does not double
- [ ] **T-2.15** Query the processed table in Athena as an independent check on the catalog
- [ ] **T-2.10** Declare the processed table in Terraform and set `--update_catalog=false` (D-16). The explicit read schema half is **done** — `takehome/orders` declares its types in the job; `inferSchema` is now only a fallback for unspec'd datasets. Do the Terraform half after T-2.12 confirms the written schema
- [ ] **T-2.16** Confirm the two assumptions in `docs/dataset-takehome-orders.md` with whoever owns the source: month-first slash dates, and the `net_amount_usd` definition
- [ ] **T-2.9** ⚠️ **Migrate state to S3 before Phase 3 starts** — state must not be local once Redshift exists (D-32)

## Phase 3 — Warehouse *(to expand)*

- [ ] **T-3.1** VPC, subnets across three AZs, S3 gateway endpoint, no NAT unless proven necessary (D-37)
- [ ] **T-3.2** Redshift Serverless namespace and workgroup (D-22)
- [ ] **T-3.3** AWS-managed admin credentials in Secrets Manager (D-25)
- [ ] **T-3.4** Schema design: `landing` / `analytics` / `ml`, and how DDL is versioned (D-24, D-38)
- [ ] **T-3.5** COPY path from processed Parquet, and who issues it (D-23)

## Phase 4 — Training *(to expand)*

- [ ] **T-4.1** Artifacts bucket and the versioned training-set layout
- [ ] **T-4.2** UNLOAD via the Redshift Data API (D-26)
- [ ] **T-4.3** SageMaker execution role
- [ ] **T-4.4** Training job in script mode (D-28)
- [ ] **T-4.5** Model Registry, with manual approval
- [ ] **T-4.6** Decide where feature engineering lives — **settle before writing transform code** (D-27)

## Phase 5 — Inference *(to expand)*

- [ ] **T-5.1** Endpoint type (D-29)
- [ ] **T-5.2** Endpoint deployment and scaling config
- [ ] **T-5.3** Exposure and auth — direct IAM invoke vs. API Gateway (D-30)
- [ ] **T-5.4** Retrain-and-promote mechanism (D-31)
- [ ] **T-5.5** End-to-end smoke test: a request returns a correct prediction

## Phase 6 — Hardening *(to expand)*

- [ ] **T-6.1** CloudWatch log groups with explicit retention (the default is forever)
- [ ] **T-6.2** Alarms on job failure, COPY failure, endpoint 5xx/latency → SNS (D-40)
- [ ] **T-6.3** AWS Budget and alarm threshold (D-39)
- [ ] **T-6.4** Runbooks: backfill, failed load, model rollback
- [ ] **T-6.5** Teardown procedure that leaves nothing billable
- [ ] **T-6.6** Encrypt Glue's CloudWatch logs with the CMK: add a key-policy grant for `logs.<region>.amazonaws.com`, flip `cloudwatch_encryption_mode` to `SSE-KMS`, verify log delivery still works, then remove the `CKV_AWS_99` skip in `envs/dev/glue.tf`

---

## Cross-cutting

- [x] **T-X.1** Log every prompt and model output in `AI_USAGE.md`
- [ ] **T-X.2** Answer Q-01 – Q-09; move each resolved decision from §5 to §4 of the scope
- [ ] **T-X.3** Keep `PROJECT_SCOPE.md` decisions and changelog current as choices get made
- [x] **T-X.4** `pre-commit` runs `terraform_fmt`, `terraform_validate`, `terraform_tflint` and `terraform_checkov` — all passing
- [x] **T-X.5** `pytest` suite: 96 tests over helpers, dataset-spec invariants and the Spark transform, including the real sample file end to end
- [ ] **T-X.6** Consider a pre-commit hook for `pytest -m "not spark"` — 0.1s, and it would catch spec mistakes before they reach a Glue run
- [ ] **T-X.7** Run the suite against pyspark 3.5 as well, to match the Spark version Glue 5.0 actually runs
