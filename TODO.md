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

Infrastructure through phase 5 is applied. The data path runs as far as the
warehouse. What has never run is everything from training onward.

1. **T-3.7** — `scripts/redshift_sql.sh sql/migrations`. The schemas do not
   exist, so the warehouse is empty and everything downstream is blocked.
2. **T-3.8 → T-3.10** — load a snapshot, then verify the two properties the
   design rests on: a repeated load must not double rows, and
   `analytics.orders` must return only the newest snapshot.
3. **T-4.8 → T-5.8** — training image check, train, approve, set
   `approved_model_package_arn`, apply, smoke test.

## Blocked

| Task | Waiting on |
|---|---|
| T-3.8, T-3.9, T-3.10 | **T-3.7** — no schemas, so nothing can be loaded or queried |
| T-4.9 | **T-3.8** — training UNLOADs from `ml.orders_training`, which needs a loaded warehouse |
| T-4.10, T-4.11 | **T-4.9** — nothing to inspect until a training run has produced a version |
| T-5.8, T-5.10 | **T-4.9** — there is no model version to approve |
| T-2.17 | A stable processed schema (T-2.10) for a rule set to target |
| T-1.9, T-3.11 | A few days of billing history |

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
- [ ] **T-1.10** Land `data/dpe_interview_takehome_data.csv` in raw at `takehome/orders/` — run `scripts/land_sample_data.sh`

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
- [x] **T-2.11** Phase 2 applied — job, roles, catalog databases, security configuration and crawler all in state
- [x] **T-1.11** Confirm objects in the artifacts bucket are KMS-encrypted — the Glue log reported `ServerSideEncryption=AES256` for the job script, which is not what D-13 specifies
- [x] **T-2.12** Land a sample file and run the job end to end; confirm Parquet lands in the right partition and the catalog table appears
- [x] **T-2.13** Run the raw crawler to discover the real schema (unblocks Q-01, Q-02, T-2.10)
- [x] **T-2.14** Verify idempotency for real: run the same date twice, confirm the row count does not double
- [ ] **T-2.15** Query the processed table in Athena as an independent check on the catalog
- [ ] **T-2.10** Declare the processed table in Terraform and set `--update_catalog=false` (D-16). The explicit read schema half is **done** — `takehome/orders` declares its types in the job; `inferSchema` is now only a fallback for unspec'd datasets. Do the Terraform half after T-2.12 confirms the written schema
- [ ] **T-2.18** Decide whether processed should partition on `order_date` instead of `ingest_date` (D-12). Snapshot partitions repeat the whole dataset per run; settle before the phase 3 COPY, since it changes what Redshift reads
- [ ] **T-2.16** Confirm the two assumptions in `docs/dataset-takehome-orders.md` with whoever owns the source: month-first slash dates, and the `net_amount_usd` definition
- [x] **T-2.9** Remote state configured: `joseroberts87-tf-backend-etl`, S3-native locking, no DynamoDB (D-32). **`terraform init -migrate-state` still has to be run** — see the README's State section

## Phase 3 — Warehouse

- [x] **T-3.1** VPC: three private subnets, S3 gateway endpoint, no IGW and no NAT, security group with no ingress and egress limited to the S3 prefix list (D-37)
- [x] **T-3.2** Redshift Serverless namespace and workgroup, 8 RPU base / 32 max, private, plus a monthly RPU-hour usage limit (D-22)
- [x] **T-3.3** AWS-managed admin credentials in Secrets Manager; IAM role for Redshift to read the processed zone and the Glue catalog (D-25)
- [x] **T-3.4** `landing` / `analytics` / `ml` schemas as ordered SQL migrations, applied via the Data API — Terraform owns infrastructure, not schema (D-24, D-38)
- [x] **T-3.5** Load path: Spectrum external schema + delete-then-insert per partition, idempotent (D-23, revised from COPY)
- [x] **T-3.6** Apply phase 3, and confirm the workgroup reaches `AVAILABLE`
- [ ] **T-3.7** Run `scripts/redshift_sql.sh sql/migrations` and confirm all **five** files apply. **Reopened 2026-08-27:** `analytics` schema does not exist, so this never applied. Terraform apply does not run migrations — they are a separate deliberate step (D-38)
- [ ] **T-3.8** Load a snapshot end to end. **Reopened 2026-08-27:** `sql/load_orders.sql` targets `landing.orders`, which cannot exist while the schemas do not — so this could not have succeeded either. Blocked on T-3.7
- [ ] **T-3.9** Verify idempotency: run the load twice for one date, confirm the row count does not double
- [ ] **T-3.10** Confirm `analytics.orders` returns only the newest snapshot after two loads on different dates
- [ ] **T-3.13** Confirm `terraform plan` reports no changes — proves what is deployed matches the committed configuration, and that no console edits have crept in
- [ ] **T-3.11** Check the bill after a day — Redshift Serverless is the first component that can cost real money, and the usage limit is the only guard (T-6.3)
- [ ] **T-3.12** Decide whether the ETL and the load should be chained by Step Functions now that there is a second step (D-17 said to revisit at exactly this point)

## Phase 4 — Training

- [x] **T-4.1** Versioned training-set layout: `s3://<artifacts>/training/<version>/`, so a model version maps to the exact rows it learned from
- [x] **T-4.2** `UNLOAD` via the Redshift Data API — training needs no VPC attachment (D-26)
- [x] **T-4.3** SageMaker execution role: training inputs and model artifacts only, ECR layer pulls scoped to the managed image's repository
- [x] **T-4.4** `ml/train.py` in script mode on the managed scikit-learn container (D-28)
- [x] **T-4.5** Model Package Group; `scripts/train_model.sh` registers versions as `PendingManualApproval` (D-31)
- [x] **T-4.6** Feature engineering split settled: warehouse selects rows and labels, the sklearn `Pipeline` owns encoding and scaling (D-27, Q-02)
- [x] **T-4.7** Phase 4 applied — SageMaker execution role and model package group exist
- [ ] **T-4.8** Verify `sagemaker_training_image` is right for the region before the first run — a wrong URI fails `create-training-job` immediately
- [ ] **T-4.9** ⚠️ **Blocked on T-3.8** — run `scripts/train_model.sh` end to end. It UNLOADs from `ml.orders_training`, which is empty until the warehouse is loaded
- [ ] **T-4.10** Confirm the registered version is `PendingManualApproval` and that nothing deployed on its own
- [ ] **T-4.11** Re-check the leakage exclusions against a real UNLOAD, not just the view definition
- [ ] **T-4.12** Decide whether `order_dow` earns its place — it is the only time-derived feature left, and the ETL's four timestamp formats make time features risky (see T-2.16)

## Phase 5 — Inference

- [x] **T-5.1** Serverless Inference — scales to zero, cold start surfaced as a 503 with retry advice (D-29)
- [x] **T-5.2** Endpoint config with `name_prefix` + `create_before_destroy`, so a new approved version rolls the endpoint without a window pointing at nothing
- [x] **T-5.3** API Gateway REST + Lambda proxy, API key, throttle and daily quota; proxy scoped to `InvokeEndpoint` on one endpoint (D-30)
- [x] **T-5.4** Promotion is approve (`scripts/promote_model.sh`) then serve (tfvars + apply) — two deliberate acts (D-31)
- [x] **T-5.6** `ml/inference.py` returning `predict_proba`; the container's default handler returns a class label, which is useless as a risk score
- [x] **T-5.7** `scripts/smoke_test_endpoint.sh` — exercises the public path exactly as an external consumer would
- [x] **T-5.12** Phase 5 applied — logs KMS key created; the rest of the stack stays gated until a model is approved
- [ ] **T-5.8** ⚠️ **Blocked on T-4.9** — approve a version, set `approved_model_package_arn`, apply, and run the smoke test (T-5.5)
- [ ] **T-5.11** Confirm the gate works in the negative: with `approved_model_package_arn` empty, `inference_enabled` is false and no endpoint, Lambda, API or log group exists
- [ ] **T-5.9** Decouple the front door from the model gate before prod: today, clearing `approved_model_package_arn` destroys the API key and URL along with the endpoint. Fine with no consumers; not fine once a key has been issued
- [ ] **T-5.10** Verify a promotion rolls the endpoint in place — approve a second version, apply, confirm the endpoint updates and keeps serving

## Phase 6 — Hardening *(to expand)*

- [ ] **T-6.1** CloudWatch log groups with explicit retention (the default is forever). **Partly done** — the Lambda and API groups are declared with `log_retention_days`, but they only exist once inference is enabled, and Glue/SageMaker still create theirs implicitly with no expiry
- [ ] **T-6.2** Alarms on job failure, COPY failure, endpoint 5xx/latency → SNS (D-40)
- [ ] **T-6.3** AWS Budget and alarm threshold (D-39)
- [ ] **T-6.4** Runbooks: backfill, failed load, model rollback
- [ ] **T-6.5** Teardown procedure that leaves nothing billable
- [ ] **T-6.6** Encrypt Glue's CloudWatch logs. **The hard half is done** — `aws_kms_key.logs` now exists with the `logs.<region>.amazonaws.com` grant, and the Lambda/API log groups exercise it. Remaining: point Glue's `cloudwatch_encryption` at that key, verify log delivery, remove the `CKV_AWS_99` skip. Note the security configuration is immutable, so this forces a replace while the job and crawler reference it
- [ ] **T-6.7** Put the predict Lambda in the VPC via a `sagemaker.runtime` interface endpoint, for prod (documented skip: `CKV_AWS_117`)
- [ ] **T-6.8** Lambda code signing for prod (documented skip: `CKV_AWS_272`)
- [ ] **T-6.9** Revisit log retention per environment — 30 days is a dev choice (documented skip: `CKV_AWS_338`)

---

## Cross-cutting

- [x] **T-X.1** Log every prompt and model output in `AI_USAGE.md`
- [ ] **T-X.2** Answer Q-01 – Q-09; move each resolved decision from §5 to §4 of the scope
- [ ] **T-X.3** Keep `PROJECT_SCOPE.md` decisions and changelog current as choices get made
- [x] **T-X.4** `pre-commit` runs `terraform_fmt`, `terraform_validate`, `terraform_tflint` and `terraform_checkov` — all passing
- [x] **T-X.5** `pytest` suite: 96 tests over helpers, dataset-spec invariants and the Spark transform, including the real sample file end to end
- [x] **T-X.6** pre-commit hook runs `pytest -m "not spark"` via the venv interpreter
- [x] **T-X.9** `scripts/redshift_sql.sh` no longer reports success on an empty file list — it exited 0 having applied nothing, which is how T-3.7 could look done
- [x] **T-X.8** `scripts/redshift_query.sh` — run a SELECT and read the rows back, for verification work
- [ ] **T-X.7** Run the suite against pyspark 3.5 as well, to match the Spark version Glue 5.0 actually runs
