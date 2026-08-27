# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A batch ETL pipeline and ML inference API on AWS, built in phases:
S3 (raw) → Glue → S3 (processed) → Redshift → SageMaker training → inference endpoint.
All infrastructure is Terraform. There is no application code beyond Glue job
scripts, and no CI.

Phases 0–1 (Terraform foundations, raw bucket, KMS) are **applied**. Phase 2
(Glue ETL) is **written and validated but not applied**. Phases 3–6 are not
started.

## Working rules specific to this project

These are project decisions, not preferences — breaking them silently is worse
than asking.

- **Never run `terraform apply`.** A developer applies manually after reviewing
  the plan (D-07). Same for `terraform destroy`.
- **Never commit or push unprompted** (D-08). Work is merged via branch → PR.
- **Append to `AI_USAGE.md` after every exchange.** This is the point of the
  repo's documentation practice, not an optional extra. Follow the template at
  the top of that file: verbatim prompt, substance of the output, and a Notes
  line saying whether it was accepted, modified or rejected. Entries are
  append-only and numbered.
- **State is remote**, in `joseroberts87-tf-backend-etl` with S3-native locking.
  The backend is declared in `envs/dev/backend.tf`; removing that file switches a
  working copy to local state (`terraform init -migrate-state`). The state bucket
  is not managed by this configuration and must keep versioning enabled. Never
  commit a `*.tfstate`, in either mode.
- **Record deviations from the scope; do not make them quietly.** When
  implementation diverges from a decision, update that decision in
  `PROJECT_SCOPE.md` with the reasoning and trade-off, and add a task to close it
  out. Existing examples: D-19 revised, D-16 and D-20 partially deviated.

## The document system

Four files interlock, and IDs are stable across all of them. Reference IDs
rather than restating their content.

| File | Holds | ID scheme |
|---|---|---|
| `PROJECT_SCOPE.md` | Architecture, decisions made (§4), decisions open (§5), unanswered questions (§6), phase plan (§7) | `D-##`, `Q-##` |
| `TODO.md` | Task tracker per phase, with a Now/Blocked summary at the top | `T-<phase>.<n>` |
| `AI_USAGE.md` | Every prompt and model output | numbered entries |
| `docs/data-layout.md` | The S3 prefix convention and reprocessing semantics | — |

A change flows: decide in `PROJECT_SCOPE.md` → track in `TODO.md` → implement →
log in `AI_USAGE.md`. Task IDs are never renumbered. When a decision moves from
open to settled, annotate it in place with a dated **Decided:** line rather than
rewriting it.

Several open questions (`Q-01` data source, `Q-02` ML target, `Q-08` cadence)
still block real work. Check §6 before assuming something is undecided by
accident.

## Commands

Two gates, neither needing AWS credentials:

```bash
pre-commit run --all-files --verbose      # terraform hooks + pytest -m "not spark"
venv/bin/python -m pytest                 # 96 tests, full suite
venv/bin/python -m pytest -m "not spark"  # 65 of them, no JVM, ~0.1s
```

The pre-commit pytest hook must invoke `venv/bin/python -m pytest`, not a bare
`pytest`: the job module imports pyspark at import time, so even the non-Spark
tests need it, and a bare `pytest` resolves to whatever is first on PATH.

Tests live in `tests/`, run against the venv in `venv/` (see
`requirements-dev.txt`). `conftest.py` stubs `awsglue` and `boto3` so the real
job module can be imported locally; tests call `evaluate_rows` and
`select_clean` directly, so they exercise deployed code rather than a copy.
Spark tests are marked `spark` and skip when no JVM is present.

**Never pass `JOB_ID` or `JOB_RUN_ID` to `getResolvedOptions`.** Glue registers
those itself whenever they appear in argv and special-cases only `JOB_NAME`, so
requesting them raises `argparse.ArgumentError: conflicting option string` and
the run dies before `main()` executes. `RESERVED_ARGS` and `argv_value()` in the
job exist for this; `tests/conftest.py` reproduces the conflict so the suite
catches a regression. The same trap applies to any other argument Glue supplies
on its own.

**`configure_session()` in the job is load-bearing — do not remove it.** It sets
`spark.sql.ansi.enabled=false` and pins the session timezone to UTC. Under ANSI
mode a failed cast or unparseable timestamp *throws*, which would abort a whole
batch on one bad row and break the quarantine design entirely; multi-format
timestamp parsing also relies on coalescing across formats where all but one
branch fails by design. Glue 5.0 (Spark 3.5) defaults ANSI off and Spark 4
defaults it on, so it is set explicitly instead of inherited. The timezone pin
keeps `ingest_date` bucketing and derived `order_date` from shifting a day.

Individual terraform pieces, if you want them directly:

```bash
terraform fmt -recursive -check           # from repo root
terraform -chdir=envs/dev validate
```

**Two checkov skips are deliberate — do not remove them without doing the work
they describe.** Each carries its reason inline: `CKV_AWS_300` in
`modules/s3_bucket/main.tf` is a verified false positive (the check stops
matching once a resource contains any `dynamic "rule"` block), and `CKV_AWS_99`
in `envs/dev/glue.tf` is a real finding deferred to T-6.6 because it needs a KMS
key-policy change that cannot be verified without applying. Any new skip should
follow that pattern: a reason, and a task if the finding is real.

Needs credentials (SSO tokens here expire often; `plan` failing with
`InvalidClientTokenId` means the token, not the config):

```bash
aws sso login --profile <profile>
terraform -chdir=envs/dev plan
terraform -chdir=envs/dev output
```

Running the ETL:

```bash
JOB=$(terraform -chdir=envs/dev output -raw glue_job_name)
aws glue start-job-run --job-name "$JOB"
aws glue start-job-run --job-name "$JOB" --arguments '{"--ingest_date":"2026-08-24"}'
aws logs tail /aws-glue/jobs/output --follow
```

## Architecture notes

**Terraform layout.** `envs/dev/` is the root module (per-environment
directories, not workspaces — D-34); `modules/s3_bucket/` is shared. Within
`envs/dev`, files split by concern: `main.tf` holds only locals, then `kms.tf`,
`storage.tf`, `glue.tf`, `iam.tf`.

**Naming.** `<project>-<env>-<component>`, with `local.bucket_suffix` =
`var.owner` (not the account ID — bucket names are therefore not
account-scoped and can collide globally). Provider `default_tags` applies
Project/Environment/ManagedBy/Owner everywhere.

**Three buckets, one per zone** (D-11), so IAM scopes per zone: `raw`
(versioned, never expires, read-only to the ETL), `processed` (unversioned,
regenerable), `artifacts` (Glue scripts, temp, Spark logs, later models). All
SSE-KMS with one customer-managed key — **any new role needs `kms:Decrypt` and
`kms:GenerateDataKey` on it**, or S3 returns an opaque AccessDenied that looks
like a bucket-policy problem.

**Prefix layout** (D-12, `docs/data-layout.md`), identical in raw and processed:

```
raw        <source>/<dataset>/<file>
processed  <source>/<dataset>/ingest_date=YYYY-MM-DD/*.parquet
```

**The zones are deliberately asymmetric.** Raw is flat — a run reads every file
under the dataset prefix. `ingest_date` is the date of the *run*, so each
processed partition is a complete snapshot of raw at that moment. Consumers must
read the newest partition; summing across partitions counts every row once per
run. Rerunning a date purges and rewrites that partition, so it stays idempotent.

The job derives its input prefix from `--source_name` and `--dataset`, so it must
match `etl_source_name` / `etl_dataset` in `envs/dev/terraform.tfvars`.
`scripts/land_sample_data.sh` lands the sample dataset; the end-to-end sequence
is in the README.

**The ETL contract.** A run is addressed by one date. The job purges the target
processed partition, then rewrites it, so reruns are idempotent and a backfill is
the same code path with a different `--ingest_date`. Glue job bookmarks are
deliberately **off** (revision to D-19) — progress lives in S3, not in service
state. Consequence: a file landing late into an already-processed partition is
not picked up automatically; that date must be rerun.

**Glue job scripts** live in `glue/jobs/` and are uploaded by Terraform using
`source_hash` (not `etag` — KMS-encrypted objects have no MD5 etag, so
etag-based drift fires on every plan). Editing a script and applying redeploys
it; the deployed script always matches the commit.

**IAM is written explicitly**, not via `AWSGlueServiceRole`, which grants access
to `aws-glue-*` buckets we do not own.

**The warehouse loads through Spectrum, not COPY.** `COPY` cannot populate a
partition column and `ingest_date` is only an S3 path segment, so `sql/` defines
an external schema over the Glue catalog and the load is `DELETE` +
`INSERT ... SELECT` for one partition — idempotent, mirroring how the ETL
rewrites that partition in S3. **Query `analytics.orders`, never
`landing.orders`**: the view pins `MAX(ingest_date)`, and the table holds every
snapshot, so a direct query counts each order once per run.

**Terraform does not own schema.** DDL is ordered files in `sql/migrations/`,
applied by `scripts/redshift_sql.sh` through the Data API, deliberately, like an
apply.

**Redshift Serverless is the only component that can run up a bill on its own.**
Base capacity is pinned to the 8 RPU floor and a monthly usage limit is set to
`deactivate` on breach. If queries suddenly fail, check the usage limit before
assuming an outage.

**The schedule exists but is disabled.** `etl_schedule_enabled = false` until
cadence is settled (Q-08) and real data is landing.

## Known temporary state

Both exist only because the real data schema is unknown, and both are closed out
by **T-2.10** once it is known — do not treat either as the intended design:

- The processed catalog table is created by the Glue sink
  (`--update_catalog=true`) rather than declared in Terraform, which D-16 calls
  for.
- CSV reads use `inferSchema`, which can infer different types for different
  files. This must not survive contact with production data.

`etl_source_name = "manual"` and `etl_dataset = "sample"` in
`envs/dev/terraform.tfvars` are placeholders pending Q-01.
