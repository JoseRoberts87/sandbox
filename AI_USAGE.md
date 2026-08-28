# AI Usage Log

A complete record of the AI assistance used to build this project: every prompt
given to a model, and what the model produced in response.

- **Order:** chronological — oldest first, newest appended at the bottom.
- **Prompts:** recorded verbatim, including typos. Not cleaned up or reworded.
- **Outputs:** the substance of what the model returned. Long code output is
  summarized with a pointer to the resulting file(s) rather than pasted in full;
  prose answers, decisions, and explanations are quoted directly.
- **Edits:** entries are append-only. If something was wrong, a later entry
  records the correction rather than rewriting history.

---

## Entry template

````markdown
### NNN — Short title

- **Date:** YYYY-MM-DD
- **Model:** <model name / id>
- **Tool:** <Claude Code CLI / web chat / IDE extension / API>
- **Files touched:** `path/one`, `path/two`

**Prompt**

```text
<verbatim prompt>
```

**Output**

<what the model returned: summary of actions taken, code produced, reasoning
given. Quote directly where the wording matters.>

**Notes**

<accepted as-is / modified by hand / rejected, and why>
````

---

## Log

### 001 — Scaffold README and AI usage log

- **Date:** 2026-08-25
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `README.md`, `AI_USAGE.md`

**Prompt**

```text
lets add a readme.md and AI_USAGE.md files where we will be recording all prompts and model outputs
```

**Output**

Inspected the repository and found it empty — a fresh `git` repo on `main` with
no commits and no tracked files. Created two files:

1. `README.md` — a skeleton with sections for overview, requirements, setup,
   usage, tests, and project structure. Project-specific content is marked with
   `<!-- TODO -->` placeholders, since the project's purpose had not been
   described yet. Includes a pointer to this log.
2. `AI_USAGE.md` — this file: conventions, a reusable entry template, and the
   log itself, seeded with this entry.

**Notes**

Accepted as-is. The `README.md` placeholders still need filling in once the
project's scope is defined.

---

### 002 — Project scope: architecture, decisions, and build order

- **Date:** 2026-08-25
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `PROJECT_SCOPE.md` (new), `README.md`

**Prompt**

```text
lets start working in this project, first we will make an outline of some of the things and we need to do and the decisions we will make. there will be no code yet. the file name will be project scope. this project will be an etl pipeline with an ml api endpoint deployed on aws via terraform. we will build out the parts one at a time. for the etl part we will use s3 to store the original raw data, Glue ETL jobs to manage the etl, redshift to store the data and sagemaker for the ML and the inference endpoint. terraform will be ran manually by a developer and all code commits will also be manual. we will later expand on these to make specific tasks
```

**Output**

Created `PROJECT_SCOPE.md`, a planning document with nine sections:

1. **What we are building** — an ASCII data-flow diagram (S3 raw → Glue →
   S3 processed → Redshift → SageMaker training → Model Registry → endpoint),
   plus goals and explicit non-goals (no CI/CD, no streaming, no multi-account,
   no BI layer, no feature store, no automated retraining).
2. **How we work** — manual Terraform apply, manual commits, one component at a
   time, all prompts logged here.
3. **Components** — a short section per service (S3, Glue, Redshift, SageMaker,
   Terraform) naming what each owns and what remains unsettled about it.
4. **Decisions already made** — `D-01`–`D-10`, the constraints given in the
   prompt, recorded as locked-in.
5. **Open decisions** — `D-11`–`D-40`, grouped by Storage / ETL / Warehouse /
   ML / Terraform-and-platform. Each states the choice, the options, and a
   recommendation with reasoning. Notable ones: separate buckets per zone
   (IAM boundary), Terraform-declared Glue catalog tables over crawlers
   (schemas belong in version control), Redshift Serverless (scales to zero for
   a batch workload), write-to-S3-then-`COPY` over Spark JDBC writes, feature
   engineering split deliberately to avoid training/serving skew, SageMaker
   Serverless Inference to start, environment directories over Terraform
   workspaces, and no NAT gateway unless something proves it needs one.
6. **Questions we need answered** — `Q-01`–`Q-09`, the problem-domain unknowns
   (data source, ML target, latency SLO, endpoint consumers, data volume,
   account/region, budget, freshness, compliance), each mapped to the decisions
   it blocks.
7. **Build order** — seven phases (Foundations → Storage → ETL → Warehouse →
   Training → Inference → Hardening), each with a deliverable and a concrete
   "done when" condition.
8. **Known risks** — training/serving skew, idle-resource cost drift, Terraform
   state loss under manual multi-developer applies, upstream schema drift,
   Redshift coupling, and manual promotion as a bottleneck.
9. **Changelog.**

Decision and question IDs are stable so later task breakdowns can reference them.

Also updated `README.md`: filled in the project description, architecture
one-liner, and build conventions now that the project's purpose is defined.
Setup/usage/test sections remain `TODO` — there is no code to document yet.

**Notes**

Accepted as-is. §5 recommendations are proposals, not settled; §6 questions are
outstanding and block roughly a third of the open decisions.

---

### 003 — Phase 0 foundations and the raw S3 bucket

- **Date:** 2026-08-25
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `.gitignore`, `modules/s3_bucket/*`, `envs/dev/*`, `README.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
lets start with setting up the terraform and the bucket where the file containing the data will be stored. that will be the very first thing we will deploy. we will start with using a local state and migrate to a remote state file later
```

**Output**

Checked the local toolchain first (Terraform 1.9.8, AWS CLI 2.18.15, SSO token
expired) and queried the Terraform registry for the current AWS provider
(6.61.0) rather than guessing a version to pin.

Created:

- **`.gitignore`** — excludes `*.tfstate*`, `.terraform/`, and saved plans.
  Load-bearing given local state: state is a plaintext record of every resource
  and will hold secrets once Redshift exists. Explicitly *keeps*
  `.terraform.lock.hcl` and `terraform.tfvars`.
- **`modules/s3_bucket/`** — reusable bucket module owning the security posture:
  public access blocked on all four flags, `BucketOwnerEnforced` ownership (ACLs
  disabled), versioning, default encryption (SSE-KMS with `bucket_key_enabled`,
  or SSE-S3 when no key is passed), a lifecycle configuration built from
  `dynamic` blocks (abort incomplete multipart uploads, cold-storage transition,
  noncurrent version expiry), and a bucket policy denying non-TLS requests.
- **`envs/dev/`** — root module with a customer-managed KMS key (rotation
  enabled), the raw bucket named `<project>-<env>-raw-<account-id>` (account ID
  as a deterministic suffix for global uniqueness, avoiding a random value in
  state), provider `default_tags`, validated input variables, and outputs for
  the bucket name/ARN and key ARN that phase 2 will consume.

Terraform version pinned `>= 1.9.0, < 2.0.0`, AWS provider `~> 6.61`, with the
S3 backend block written but commented out and annotated with the migration
steps — including the note that `use_lockfile` needs Terraform >= 1.10 while
1.9.8 is installed, so upgrading before migrating avoids a throwaway DynamoDB
lock table.

**Verification run:** `terraform fmt -recursive` (clean), `terraform init`
(provider 6.61.0 resolved, lock file written), `terraform validate` (**Success**).
`terraform plan` reached the provider and failed at
`STS: GetCallerIdentity — InvalidClientTokenId` because the SSO token is expired.
So the configuration is syntactically and semantically valid but **has not been
planned against a real account**. Also confirmed via `git status` that no state
or provider files would be committed.

Updated `PROJECT_SCOPE.md` (D-32 rewritten as decided-local-first, with the
constraint that state must move remote before Redshift lands in Phase 3; status
note added to §7; changelog entry) and `README.md` (requirements, setup, usage,
teardown, structure).

**Notes**

Accepted as-is, unapplied. Two assumptions were made rather than blocking:
`aws_region = "us-east-1"` and `project = "sandbox"` — both are placeholders
pending Q-06, and both force resource replacement if changed after the first
apply.

---

### 004 — Task tracker

- **Date:** 2026-08-25
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `TODO.md` (new), `README.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
lets add a series of todos in a file so that we can track progress
```

**Output**

Created `TODO.md`, 54 tasks across the seven phases from `PROJECT_SCOPE.md` §7,
with stable IDs (`T-<phase>.<n>`) and a marker legend (done / blocked / in
progress). Structure:

- A **Now** section naming the next three actions, and a **Blocked** table
  giving the reason for each stalled task (expired credentials, Q-06, Q-01).
- **Phases 0 and 1** as concrete tasks — 10 already complete from entry 003,
  the rest covering apply, posture verification, and the prefix layout.
- **Phases 2–6** deliberately coarse, marked *(to expand)*, each item pointing
  at the decision it depends on.
- **Cross-cutting** tasks: keeping this log current, resolving Q-01–Q-09, and
  adding `tflint`/`checkov` once there is more than one module.

Two ordering constraints were encoded as tasks rather than left implicit:
**T-2.9** gates Phase 3 on migrating state off the laptop (per D-32), and
**T-0.10** puts the Terraform upgrade before that migration so it can use native
S3 lockfiles instead of a DynamoDB table that would later be removed.

Cross-linked from `README.md` and `PROJECT_SCOPE.md` §7.

**Notes**

Accepted as-is. Task counts and completion state reflect work through entry 003;
nothing has been applied to AWS.

---

### 005 — Phase 2: Glue ETL, and the raw/processed prefix layout

- **Date:** 2026-08-26
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `docs/data-layout.md` (new), `glue/jobs/raw_to_processed.py` (new), `envs/dev/{main,kms,storage,glue,iam,variables,outputs}.tf`, `envs/dev/terraform.tfvars`, `modules/s3_bucket/{main,variables}.tf`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
i have updated some of the todos as i completed them myself. lets proceed with the document prefix layout being `<source>/<dataset>/ingest_date=YYYY-MM-DD/` and lets proceed with the ETL phase. for now, the AWS Glue service will be used for the ETL.
```

**Output**

Read the current `TODO.md` and Terraform state first to pick up work done
outside this session: phases 0 and 1 were applied, Terraform upgraded to 1.15.8,
and `bucket_suffix` had been changed from the account ID to `var.owner` (so the
deployed bucket is `sandbox-dev-raw-data-platform`). Followed that convention for
the new buckets and corrected the now-inaccurate comment that still described an
account-ID suffix.

**`docs/data-layout.md`** (T-1.7) — the prefix layout as a settled convention:
segment definitions and naming rules, why Hive-style `ingest_date=` partitioning
(catalog recognition, partition pruning, addressable reruns), per-zone
descriptions with worked examples, the artifacts-bucket prefix table, lineage
columns, landing and reprocessing commands, and an open note that event-date
partitioning may be needed once the schema is known.

**Terraform** — split `envs/dev` into `main.tf` (locals), `kms.tf`, `storage.tf`,
`glue.tf`, `iam.tf`; resource addresses are unchanged, so the existing resources
should not re-plan. Added:

- **Processed and artifacts buckets** (T-1.8). Processed is unversioned —
  regenerable from raw, so retaining superseded versions of rewritten partitions
  is not worth the storage. Artifacts is versioned. Extended the bucket module
  with an `expiring_prefixes` variable so Glue temp and Spark event logs expire
  after 7 days instead of accumulating silently.
- **Glue catalog databases** per zone, plus an on-demand crawler over raw for
  schema discovery only.
- **`aws_glue_job`** — Glue 5.0, `G.1X` × 2, 60-minute timeout,
  `max_concurrent_runs = 1`, bookmarks disabled, script uploaded by Terraform
  with `source_hash` (not `etag`, which KMS-encrypted objects do not expose).
- **IAM** — explicit least-privilege policies rather than `AWSGlueServiceRole`,
  which grants broad access to `aws-glue-*` buckets that are not ours. Raw is
  read-only to the job. Separate crawler role; scheduler role with an
  `aws:SourceAccount` confused-deputy guard.
- **EventBridge Scheduler** targeting `glue:startJobRun`, **created disabled**.

**`glue/jobs/raw_to_processed.py`** — reads one `ingest_date` partition, resolves
`latest`/`yesterday`/`today`/explicit dates, normalizes column names to
Athena-safe `snake_case` (with collision disambiguation), fails closed on an
empty partition or missing required columns, trims strings, stamps lineage
(`etl_source_file`, `etl_processed_at`, `etl_job_run_id`), purges the target
partition, then writes Snappy Parquet through the Glue catalog sink.

**Decision surfaced rather than made silently:** D-19 was revised — job bookmarks
are off. Because raw is partitioned by `ingest_date`, a run is addressed by a
date and purge-then-write makes reruns idempotent, so a backfill is the same code
path with a different argument. Bookmarks would put progress state in the Glue
service where it can drift from S3. The cost is that late-arriving files in an
already-processed partition need a manual rerun of that date. Recorded in the
scope doc with the trade-off stated.

Updated `PROJECT_SCOPE.md` (D-11, D-12, D-17, D-18, D-21, D-38 decided; D-16 and
D-20 partially decided; D-19 revised; status and changelog), `TODO.md` (T-1.7,
T-1.8 and seven phase-2 tasks closed; five new tasks added for apply, end-to-end
run, crawl, idempotency check and Athena verification), and `README.md`.

**Verification run:** `terraform fmt -recursive -check` clean, `terraform
validate` **Success**, `python3 -m py_compile` on the job script passes.
`terraform plan` was **not** run — the SSO token is expired again — so this is
unapplied and has never executed against real data.

**Notes**

Accepted as-is, unapplied. Two deliberate deviations from the scope, both
recorded: the processed catalog table is created by the job's sink rather than
declared in Terraform (D-16), and `inferSchema` is used for CSV — both are
temporary because the real schema is unknown, and both are closed out by T-2.10
once it is. `etl_source_name = "manual"` and `etl_dataset = "sample"` are
placeholders pending Q-01.

---

### 006 — CLAUDE.md

- **Date:** 2026-08-26
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `CLAUDE.md` (new), `README.md`

**Prompt**

```text
/init

Please analyze this codebase and create a CLAUDE.md file, which will be given to future instances of Claude Code to operate in this repository.
```

**Output**

Checked for existing agent configuration first — no `CLAUDE.md`, no
`.cursorrules`, no `.cursor/rules/`, no `.github/copilot-instructions.md`.

Created `CLAUDE.md` covering what a future session cannot infer from any single
file:

- **Working rules** that are project decisions rather than preferences: never
  `terraform apply` or `destroy` (D-07), never commit unprompted (D-08), append
  to `AI_USAGE.md` every exchange, local state is the only record of what exists,
  and deviations from the scope get recorded in `PROJECT_SCOPE.md` rather than
  made quietly.
- **The document system** — how `PROJECT_SCOPE.md`, `TODO.md`, `AI_USAGE.md` and
  `docs/data-layout.md` interlock, that `D-##`/`Q-##`/`T-##` IDs are stable and
  should be referenced rather than restated, and the decide → track → implement →
  log flow.
- **Commands**, split by whether they need AWS credentials, with the note that a
  `plan` failing on `InvalidClientTokenId` is an expired SSO token rather than a
  broken configuration. Stated plainly that there is no test suite.
- **Architecture notes** that require reading several files to reconstruct: the
  `envs/` + `modules/` split, `bucket_suffix = var.owner` and its global-collision
  caveat, the three zones and their differing versioning, the KMS grant that new
  roles always need, the date-addressed idempotent ETL contract and why bookmarks
  are off, `source_hash` versus `etag` for script upload, and why IAM is written
  explicitly instead of using `AWSGlueServiceRole`.
- **Known temporary state** — the sink-managed catalog table and `inferSchema`,
  both flagged as not-the-intended-design and tied to T-2.10, plus the
  placeholder `etl_source_name` / `etl_dataset` values.

Added `CLAUDE.md` to the project structure listing in `README.md`.

**Notes**

Accepted as-is. No repository rules from other tools existed to fold in.

---

### 007 — pre-commit: fixing what it found

- **Date:** 2026-08-26
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/glue.tf`, `envs/dev/kms.tf`, `envs/dev/versions.tf`, `modules/s3_bucket/{main,versions}.tf`, `CLAUDE.md`, `README.md`, `TODO.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
i added precommit which you can run using pre-commit run --all-files --verbose
```

**Output**

First run: `terraform_fmt`, `terraform_validate` and `terraform_tflint` passed;
`terraform_checkov` failed with 6 findings across 3 distinct checks (120 passed).

**CKV_AWS_300** (×3, "lifecycle configuration sets period for aborting failed
uploads") — investigated rather than suppressed, because the module *does* set
`abort_incomplete_multipart_upload`. Read the check's source
(`S3AbortIncompleteUploads.py`), then confirmed the behaviour empirically with
two minimal test cases: a lifecycle configuration with only the static abort rule
**passes**; adding any `dynamic "rule"` block makes the identical abort rule
**fail**. Verified false positive — suppressed with a `checkov:skip` comment
recording that evidence.

**CKV_AWS_195** (×2, Glue job and crawler have no security configuration) — a
real gap, and one previously deferred to phase 6. Added
`aws_glue_security_configuration` with S3 `SSE-KMS` and job-bookmarks `CSE-KMS`
using the existing CMK, attached to both the job and the crawler.

**CKV_AWS_297** (×1, EventBridge Scheduler CMK) — real, fixed by setting
`kms_key_arn` on the schedule. Since the key is no longer S3-only, updated its
description to match (an in-place update, not a replacement).

That surfaced a fourth check, **CKV_AWS_99**, which requires *all three* Glue
encryption modes including CloudWatch. Read its source to confirm. Left
CloudWatch encryption `DISABLED` and suppressed the check, because enabling it
requires a KMS key-policy grant to `logs.<region>.amazonaws.com` — a change that
silently breaks log delivery for every job run if wrong, and that cannot be
verified without applying against a real account. The skip comment states that it
is a deferred real finding rather than a false positive, and **T-6.6** was added
to implement, verify, and then remove it.

Also corrected the `required_version` comments in both `versions.tf` files, which
still claimed Terraform 1.9.8 after the upgrade to 1.15.8.

**Verification run:** `pre-commit run --all-files --verbose` — all four hooks
**Passed**, checkov 123 passed / 0 failed / 4 skipped.

Updated `CLAUDE.md` (pre-commit is now the gate, plus a rule that any skip must
carry a reason and a task if the finding is real), `README.md`, `TODO.md` (T-X.4
closed, T-6.6 added) and the scope changelog.

**Notes**

Accepted as-is, unapplied. The two suppressions are different in kind and are
labelled as such: CKV_AWS_300 is a tool limitation with reproduction steps
recorded, CKV_AWS_99 is a genuine gap with a tracked task. Neither should be
removed without re-checking the reasoning.

---

### 008 — Real dataset: declared schema, cleaning rules, and quarantine

- **Date:** 2026-08-26
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `glue/jobs/raw_to_processed.py`, `docs/dataset-takehome-orders.md` (new), `docs/data-layout.md`, `envs/dev/{glue,variables}.tf`, `envs/dev/terraform.tfvars`, `TODO.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
i added a file at /Users/jrob/repos/scraps/sandbox/data/dpe_interview_takehome_data.csv, use this data to update raw_to_processed.py
```

**Output**

Profiled the file before writing any code — 19 rows, 13 columns — and found it
seeded with deliberate defects:

| Problem | Detail |
|---|---|
| Four timestamp formats in one column | `yyyy-MM-dd HH:mm:ss` (10), `MM/dd/yyyy` (4), `dd-MMM-yyyy` (3), ISO-8601 with `T…Z` (2) |
| Currency symbol in a numeric column | `$159.28` in `unit_price_usd` |
| Case variants | `region` 7 distinct → 4 real; `channel` 6 → 4 |
| Whitespace padding | `category` 10 distinct → 6 real |
| Blank numeric | one empty `shipping_days` |
| Cross-row conflict | `SKU-1067` maps to two different products and categories |

`order_id` is unique, and no slash date is ambiguous — every one has a day > 12,
which is the only reason month-first parsing is safe here.

Rewrote the job around a **declared spec** (`DATASET_SPECS`, keyed
`"<source>/<dataset>"`) rather than inference: column list, target types, a
cleaning rule per column, and constraints. CSV is read as all-strings and cast
deliberately, because `inferSchema` can choose different types for different
files of the same feed. Datasets without a spec keep the previous generic
behaviour, so nothing regressed.

Cleaning rules are semantic rather than uniform: `code` (uppercase) for
identifiers and `region`, `enum` (lowercase) for closed sets and grouping keys
where case must not create duplicate join values, `text` (case preserved) for
display strings, `money` for currency stripping.

**The main design decision: bad rows are quarantined, not dropped or nulled.**
This extends D-20 into three tiers — structural problems fail the run
immediately; row-level failures are written to
`_rejected/<source>/<dataset>/ingest_date=.../` with their original values and a
`reject_reason` listing every reason; the run then fails only if the reject rate
exceeds `--max_reject_pct` (default 5%). Rejects are written *before* the
threshold is evaluated, so a failed run still leaves the evidence. Also added
duplicate-primary-key handling (keep the most recent, quarantine the rest) and
derived `order_date` / `gross_amount_usd` / `net_amount_usd`.

Fixed two problems found while reviewing the draft: the dedup ordering was
inferred from column presence rather than declared (now `dedup_order_by` in the
spec), and a rerun producing zero rejects would have left the previous run's
rejects in place — an idempotency bug in the reject path.

**Verification run:** Java and pyspark are not installed locally, so the Spark
job could not be executed. Instead, mirrored the spec's rules in plain Python —
importing the real `DATASET_SPECS` from the job module with the Glue and Spark
imports stubbed, so the check reflects the actual spec — and ran it over the
file: **19 rows in, 19 accepted, 0 rejected**, with all four timestamp formats
parsed, `$159.28` → `159.28`, regions collapsed to 4, categories to 6, and the
blank `shipping_days` becoming NULL rather than a reject. Because that exercises
none of the reject logic, ran a second pass with five deliberately broken rows
and confirmed each is rejected with the right reason, including one row
accumulating three reasons. `pre-commit run --all-files` passes all four hooks.

Wired `terraform.tfvars` to `takehome/orders`, added `etl_max_reject_pct`, and
set `--csv_infer_schema=false`. Wrote `docs/dataset-takehome-orders.md` (schema,
the profile findings, cleaning rules, derived-column definitions, reject
behaviour) and documented the `_rejected/` prefix in `docs/data-layout.md`.

**Notes**

Accepted as-is. **The Spark job itself has still never run** — the rules are
verified, the execution is not (T-2.12). Two assumptions are recorded in the
dataset doc and tracked as T-2.16: that slash dates are month-first (safe on this
file, silently wrong if a future file contains `03/04/2025`), and that
`net_amount_usd = quantity × unit_price × (1 − discount_pct)`.

---

### 009 — pytest suite, and two bugs it found

- **Date:** 2026-08-26
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `tests/{conftest,test_helpers,test_spec,test_transform}.py` (new), `pytest.ini` (new), `requirements-dev.txt` (new), `glue/jobs/raw_to_processed.py`, `README.md`, `CLAUDE.md`, `TODO.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
i created a venv and installed pyspark, lets add unit tests using pytest
```

**Output**

Installed `pytest` into the existing `venv/` (it had `pyspark` but no test
runner). Refactored `main()` first — the row evaluation and column projection
were inline, so testing them would have meant duplicating the logic. Extracted
`evaluate_rows()` and `select_clean()`; `main()` now orchestrates and the tests
call the same functions the job does.

**96 tests in three files:**

- `test_helpers.py` (41) — name normalization and collision disambiguation,
  `as_bool`, ingest-date resolution including impossible dates like `2025-02-30`,
  `latest_partition` against a stubbed S3 paginator, and argument resolution
  including the blank-value-falls-back-to-default case Terraform can produce.
- `test_spec.py` (24) — invariants over *every* entry in `DATASET_SPECS`, so a
  dataset added later inherits them. The one that matters most:
  `allowed` values must match their cleaning rule's casing, because an `enum`
  column lowercases before comparing and an allowed list containing `"Retail"`
  would quarantine 100% of rows for no visible reason.
- `test_transform.py` (31, marked `spark`) — the four timestamp formats, currency
  and thousands-separator stripping, blank-optional-becomes-NULL, every reject
  reason, multiple reasons on one row, duplicate-key resolution, derived amounts,
  and the real sample file end to end (19 rows, 0 rejects, canonical dimension
  sets, the `$159.28` row, the SKU-1067 conflict warning).

`conftest.py` stubs `awsglue` and `boto3` so the real job module imports locally,
and provides a Spark fixture that skips cleanly when no JVM is present.

**Two real bugs, both in the job rather than the tests:**

1. **ANSI mode.** The first run failed 8 tests with `CANNOT_PARSE_TIMESTAMP`.
   Spark 4 enables `spark.sql.ansi.enabled` by default, under which a failed cast
   or unparseable timestamp *throws* instead of returning NULL. That breaks the
   entire quarantine design — one bad value would abort the batch rather than be
   rejected with a reason — and it also breaks multi-format parsing, which
   coalesces across formats where all but one branch fails by design. Glue 5.0
   (Spark 3.5) defaults it off, so the job was silently depending on an inherited
   default it never stated.
2. **Session timezone.** With that fixed, timestamps still came back a day early:
   collecting a Spark timestamp converts to the *driver's* local zone. The parse
   was correct, but it exposed that the job never pinned its session timezone —
   under a non-UTC session, `ingest_date` bucketing and derived `order_date` can
   land a day out.

Both are now set explicitly in a new `configure_session()`, which the test
fixture calls too, so the tests cannot pass under a configuration the deployed
job does not use.

**Verification run:** `venv/bin/python -m pytest` — **96 passed**;
`-m "not spark"` — 65 passed in 0.09s; `pre-commit run --all-files` — all four
hooks pass.

**Notes**

Accepted as-is. `requirements-dev.txt` pins `pyspark==4.2.0`, deliberately newer
than the Spark 3.5 that Glue 5.0 runs — the stricter runtime is what surfaced the
ANSI dependency. The divergence is real, though: a bug specific to Spark 3.5
would not be caught here, tracked as T-X.7. The Glue job itself still has never
executed against AWS (T-2.12).

---

### 010 — Path plumbing for an end-to-end Glue run

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/iam.tf`, `scripts/land_sample_data.sh` (new), `.pre-commit-config.yaml`, `README.md`, `docs/dataset-takehome-orders.md`, `CLAUDE.md`, `TODO.md`

**Prompt**

```text
i had to fix an issue with the policy, make sure you dont revert that. lets also make sure this path `<source>/<dataset>/ingest_date=YYYY-MM-DD/` is added in all the places it needs to be added so that i can test the glue job
```

Mid-turn: `stop checking for credentials for aws`

**Output**

Located the user's fix first: a `ReadGlueSecurityConfiguration` statement
(`glue:GetSecurityConfiguration` on `*`) added to the **crawler** role in
`aa154c5`, needed because the crawler has a security configuration attached. Left
it untouched and verified afterwards that the diff was purely additive
(9 insertions, no deletions).

**Found the same gap on the job role.** The Glue job carries the same security
configuration but its policy had no such statement, so it would hit the identical
denial on first run. Added the matching statement.

**Path audit.** Traced every place the layout is constructed or referenced. The
job derives its paths from `--source_name`/`--dataset` and `terraform.tfvars`
already points at `takehome/orders`, so the pipeline itself was correct — but the
README's landing example still used an invented `acme_crm/customers` path, which
is what someone following the docs would actually type.

- Added **`scripts/land_sample_data.sh`** — resolves the bucket from terraform
  outputs, defaults to today's UTC date, validates the date format, and lands the
  file at `takehome/orders/ingest_date=YYYY-MM-DD/`, then prints the command to
  run the job over that partition.
- Rewrote the README's landing section around the real dataset and added a
  **step-by-step end-to-end test sequence** (apply → land → run → watch → verify
  the partition → verify the catalog table), including the note that Athena
  verification would need a workgroup and results bucket that do not exist yet,
  so the check uses `aws glue get-table` instead.
- Cross-referenced the prefix-must-match-tfvars constraint in `CLAUDE.md` and the
  dataset doc.

**Fixed the failing pre-commit hook.** The user had added a `pytest (non-Spark)`
hook; it failed with 65 collection errors. Cause: `entry: pytest` with
`language: system` resolved to `/Users/jrob/miniconda3/bin/pytest`, which has no
pyspark — and the job module imports pyspark at import time, so even the
non-Spark tests need it. Changed the entry to `venv/bin/python -m pytest`.

**Verification run:** `pre-commit run --all-files` — all **five** hooks pass
(the four terraform hooks plus pytest). Full suite: 96 passed.

Also confirmed **without contacting AWS** that the deployed job script is current,
by comparing the `source_hash` recorded in local terraform state against an MD5
of the working file — they match, so `apply` will not replace the script and the
only pending change is the IAM statement.

**Notes**

Accepted as-is. Per the mid-turn instruction, stopped probing AWS credentials;
the remaining verification was done against local state and files. The Glue job
still has not executed — T-1.10 and T-2.12 are the next steps and need the apply
first, since the job would otherwise be denied `GetSecurityConfiguration`.

---

### 011 — Flatten the raw path

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `glue/jobs/raw_to_processed.py`, `scripts/land_sample_data.sh`, `envs/dev/glue.tf`, `tests/test_helpers.py`, `docs/data-layout.md`, `docs/dataset-takehome-orders.md`, `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
update the file path to just takehome/orders/
```

**Output**

Asked one clarifying question first, because the change reaches past the landing
script: the job addresses runs *by* the `ingest_date` partition, and that is what
makes reruns idempotent. Offered three scopes — raw only, raw flat with processed
partitioned on `order_date` instead, or drop partitioning entirely. **Answer: raw
only.**

Implemented:

- **Raw is now flat** — `<source>/<dataset>/<file>`. A run reads every file under
  the dataset prefix.
- **Processed keeps `ingest_date`**, now explicitly the date of the *run* rather
  than a property of the data.
- `--ingest_date` **defaults to `today`** (was `latest`). `latest` was resolving
  against raw, which no longer has partitions to discover; it now resolves
  against *processed* and means "redo the most recent load in place", which keeps
  `latest_partition()` useful and its four tests meaningful.
- `scripts/land_sample_data.sh` no longer takes a date and lands at
  `takehome/orders/<file>`.

**The consequence worth stating,** flagged before implementing and now documented
in four places: because each run reprocesses the whole of raw, every processed
partition is a *complete snapshot*, not an increment. Consumers must read the
newest partition — summing across partitions counts every row once per run.
Rerunning a date still purges and rewrites it, so idempotency is unaffected.

Updated D-12 in the scope with the revision, the reasoning (partitioning raw by
arrival date added a path segment carrying no information, since every partition
held the same single file), and the two things it leaves open: raw should be
partitioned again if a real feed delivers dated drops (Q-01), and processed may
be better partitioned on the derived `order_date` — added as **T-2.18**, to be
settled before the phase 3 COPY since it changes what Redshift reads.

**Verification run:** 96 tests pass (`test_applies_defaults_for_omitted_options`
updated for the new default), all five pre-commit hooks pass, and a repo-wide
grep confirms no stale `raw/...ingest_date=` paths remain in scripts or
Terraform.

**Notes**

Accepted as-is. Per the standing instruction, no AWS calls were made. The job
still has not executed; `terraform apply` is needed first for the pending IAM
statement, and the job argument default changed, so apply also updates the job
definition.

---

### 012 — First real run: `--JOB_RUN_ID` conflict

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `glue/jobs/raw_to_processed.py`, `tests/conftest.py`, `tests/test_helpers.py`, `envs/dev/glue.tf`, `CLAUDE.md`, `TODO.md`

**Prompt**

```text
while running the job we got this log [full Glue driver log, ending in]
argparse.ArgumentError: argument --JOB_RUN_ID: conflicting option string: --JOB_RUN_ID
```

**Output**

The job failed at startup, in `resolve_args()`, before `main()` did any work.

**Cause.** `awsglue.utils.getResolvedOptions` builds an argparse parser and
pre-registers the reserved arguments — `JOB_NAME`, `JOB_ID`, `JOB_RUN_ID` —
whenever they appear in argv, special-casing only `JOB_NAME`. `JOB_RUN_ID` was
in `OPTIONAL_ARGS`, so the second `getResolvedOptions` call asked argparse to add
an option it already had. Glue always passes `--JOB_RUN_ID`, so this could never
have worked; the first successful call was the one that did not request it.

**Fix.** Introduced `RESERVED_ARGS = ("JOB_ID", "JOB_RUN_ID")`, removed them from
`OPTIONAL_ARGS`, and added `argv_value()` to read them straight from argv, with a
fallback so the `etl_job_run_id` lineage column is never null.

**The more important fix was to the test stub.** The suite had 96 passing tests
over a job that could not start, because `conftest.py`'s `getResolvedOptions`
stub resolved whatever it was asked for and never modelled the reserved-argument
conflict. Updated it to pre-register the reserved names and raise
`GlueArgumentConflictError` on a conflicting request, then added five tests: one
reproducing Glue's real argv, one pinning the awsglue behaviour being worked
around, one asserting reserved names never appear in `REQUIRED_ARGS` or
`OPTIONAL_ARGS`, plus fallback and `argv_value` coverage.

**Verified the regression test actually catches it** by reintroducing the bug in
a scripted round-trip: with `JOB_RUN_ID` back in `OPTIONAL_ARGS` the suite fails
with `GlueArgumentConflictError`; restored, it passes. A green suite that never
fails on the bug it claims to cover is worth nothing.

Also removed `--required_columns = ""` from the Terraform job arguments. The job
defaults it anyway, and an empty-valued argument on the command line is a
needless argparse risk — it sat immediately after the argument that failed, so
whether it parses was never actually established.

**Verification run:** 101 tests pass; all five pre-commit hooks pass.

**Notes**

Accepted as-is. Noted one thing from the log for later (**T-1.11**): the job
script downloaded from the artifacts bucket reported
`ServerSideEncryption=AES256`, not the KMS encryption D-13 specifies. Not
blocking the run, but it contradicts a documented decision and should be checked.
The job still needs `terraform apply` before the next attempt — this fix changes
the script, and the IAM statement from entry 010 is still pending.

---

### 013 — Remote state in S3, with local state still available

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/backend.tf` (new), `envs/dev/versions.tf`, `.gitignore`, `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
lets migrate the state to s3 using this bucket joseroberts87-tf-backend-etl and make sure to include instructions on the readme on how to use either a local state or a remote state
```

**Output**

Configured the S3 backend and documented both modes. **Did not run
`terraform init -migrate-state`** — it is a state operation at least as
consequential as an apply, and D-07 keeps Terraform runs with a developer. The
README carries the exact sequence.

**`envs/dev/backend.tf`** — the backend in a file of its own rather than inside
`versions.tf`. Switching between remote and local then means renaming a file
instead of commenting out lines inside a block, which is the version of this
that goes wrong at 2am. Removed the stale commented-out block from
`versions.tf`.

```
bucket  joseroberts87-tf-backend-etl
key     envs/dev/terraform.tfstate
lock    use_lockfile — S3-native conditional writes, no DynamoDB table
```

The Terraform upgrade from T-0.10 pays off here: `use_lockfile` needs >= 1.10, so
there is no lock table to create now and remove later.

**README gained a `State` section** covering: the backend settings; that the
state bucket is deliberately outside Terraform's ownership (it cannot hold the
state describing itself) and **must have versioning enabled**, being the only
recovery path from a corrupted write; the one-time migration with a backup step
first and a `terraform state list` + `terraform plan` verification before
deleting anything local; how to switch to local state and back; and when each is
appropriate.

The migration sequence deliberately backs up local state *before* migrating and
only removes it *after* a clean plan, with an explicit "if this looks wrong,
stop and restore" instruction. The failure mode being guarded against is a
migration that silently lands in the wrong bucket or key and leaves Terraform
believing the infrastructure does not exist.

Added `backend.tf.disabled` to `.gitignore` — running against local state is a
per-working-copy choice, not a repo-wide one. Updated the state claims in
`CLAUDE.md`, closed D-32 in the scope with the reasoning, and marked T-2.9 done
while noting the migration command itself is still outstanding.

**Verification run:** all five pre-commit hooks pass. `terraform validate` still
works with an uninitialised backend because the hook runs `init -backend=false`.

**Notes**

Accepted as-is. Two things assumed and worth confirming: the bucket is in
`us-east-1` (it must match `region` in `backend.tf`, or init fails), and it
already has versioning enabled. Nothing was verified against AWS, per the
standing instruction.

---

### 014 — Phase 3: Redshift Serverless, schemas, and the load path

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/{network,redshift}.tf` (new), `envs/dev/{iam,variables,outputs}.tf`, `envs/dev/terraform.tfvars`, `sql/` (new), `scripts/redshift_sql.sh` (new), `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
lets now move to phase 3
```

**Output**

Flagged first that §7's rule — a phase should not start until the previous one is
verified — is being departed from: the Glue job has still never completed a run
(T-2.12), and phase 3's load depends on the catalog table that run registers.
Built phase 3 anyway, as asked, and recorded the dependency in the scope status
and as a blocker on T-3.8.

**Networking** (`network.tf`) — a VPC that exists only because Redshift
Serverless requires three AZs. No internet gateway, no NAT (a NAT bills hourly
forever in an environment meant to idle near zero), an S3 gateway endpoint
because it is free, a security group with **no ingress at all** since the Data
API is an AWS API call rather than VPC traffic, and egress restricted to the S3
prefix list. The default security group is claimed and left empty.

**Redshift** (`redshift.tf`) — Serverless at the 8 RPU floor, 32 RPU ceiling,
private, `manage_admin_password = true` so the credential lives in Secrets
Manager and never in state. Added an `aws_redshiftserverless_usage_limit` of 40
RPU-hours/month with `breach_action = deactivate`: this is the first component
that can run up a bill unattended and there is no budget alarm yet, so the limit
is a hard stop. Documented that it will look like an outage if it fires.

**D-23 revised: the load goes through Spectrum, not COPY.** `COPY` cannot
populate a partition column, and `ingest_date` exists only as an S3 path segment
— a COPY-based load would need a staging table plus a literal date injected per
run. A Spectrum external schema over the Glue catalog the ETL already maintains
exposes `ingest_date` as a real column, making the load a plain `DELETE` +
`INSERT ... SELECT` for one partition: idempotent, and mirroring exactly how the
ETL rewrites that partition in S3. The substance of D-23 stands — data moves
S3 → warehouse, never over Spark JDBC.

**Schemas** (`sql/`) — `landing`, `analytics`, `ml` as ordered, re-runnable
migrations. The load-bearing piece is `analytics.orders`, a view pinned to
`MAX(ingest_date)`: because every partition is a full snapshot (D-12), querying
`landing.orders` directly counts each order once per run. The view is the safe
entry point and the table is the history — this is the warehouse-side answer to
the hazard that the flat-raw change introduced.

**`scripts/redshift_sql.sh`** — runs a file or a directory through the Data API,
substituting `${placeholders}` from terraform outputs and `KEY=VALUE` arguments.
A file naming a placeholder with no value **fails** rather than substituting an
empty string, which would otherwise produce SQL like `IAM_ROLE ''`. Statements go
as one batch, which the Data API runs in a single transaction — so a file applies
completely or not at all, and the load's delete-then-insert cannot half-apply.
That is also why the SQL carries no explicit `BEGIN`/`COMMIT`.

**Verification run:** `terraform validate` passes, which confirms every Redshift
Serverless attribute name against the provider schema. All five pre-commit hooks
pass with no new checkov findings. Exercised the script's rendering logic offline
against all five SQL files: statement splitting is correct (3, 1, 1, 1, 2), and a
missing `ingest_date` fails loudly. 101 tests still pass.

**Notes**

Accepted as-is, unapplied. Two things to watch on first apply: `enhanced_vpc_routing`
is on, which forces S3 traffic through the gateway endpoint — it is behind a
variable because it is the first suspect if a load fails with an opaque S3 or KMS
timeout. And the usage limit deactivates the workgroup on breach, which is
protective but will present as an outage. T-3.12 was added because D-17 said to
revisit Step Functions once a second pipeline step existed; the load is that step.

---

### 015 — Phase 4: training, and the feature-engineering split

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `ml/train.py` (new), `sql/migrations/005_ml_training_view.sql` (new), `sql/unload_training_set.sql` (new), `scripts/train_model.sh` (new), `tests/test_train.py` (new), `envs/dev/sagemaker.tf` (new), `envs/dev/{variables,outputs}.tf`, `requirements-dev.txt`, `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
lets proceed to phase 4
```

**Output**

Asked one question first — Q-02, the ML target — because it is the open question
the scope flags as blocking D-27 and D-28, and it determines what the training
script contains. Offered three options grounded in what the data actually
supports. **Answer: refund risk, binary classification.**

**T-4.6 / D-27, the decision that matters.** The split runs along one line: row
selection and labelling in the warehouse, row-local transforms in the model
artifact. `ml.orders_training` is SQL — reviewable in a diff — and the artifact
is a single sklearn `Pipeline` containing imputation, encoding, scaling and the
classifier, so inference physically cannot preprocess differently from training.

Three leakage exclusions are documented in the view rather than left implicit:
`shipping_days` is unknown at scoring time; `pending` orders are excluded because
they have not resolved, and at scoring time every new order is pending; and the
**hour** of `order_ts` is excluded because 7 of 19 source rows carry a date with
no time — hour would encode which timestamp format a row arrived in, a property
of our ETL rather than of the order.

Built: the training view, `UNLOAD` to a versioned prefix via the Data API (so
training needs no VPC attachment, and the unloaded files *are* the reproducible
artifact), a SageMaker execution role, a Model Package Group, `ml/train.py`, and
`scripts/train_model.sh` — unload, package, train, register as
`PendingManualApproval`. A retrain is a script, never a `terraform apply`.

**Verification run — the training path was actually executed, on real data.**
Installed scikit-learn/pandas, then built a training set locally by running the
**real** Spark transform over `data/dpe_interview_takehome_data.csv` and applying
the same SELECT as the view: 15 rows (19 minus 4 pending), 6 refunded. Trained on
it: cross-validated ROC AUC **0.537**, which the script itself reports alongside a
warning that the dataset is far too small for the number to mean anything.
Reloaded the artifact and confirmed it carries its preprocessing and returns a
probability for a row with an unseen region, channel and category rather than
raising — a 500 on an unseen value is the obvious way an endpoint like this
fails.

**19 tests** added, including a guard that the view's SELECT list and the
script's feature list agree; verified it fires by introducing drift and watching
the suite fail. Also asserted the leakage exclusions and that the view reads
`analytics.orders` rather than `landing.orders` — training on the history table
would see each order once per ETL run.

Checkov flagged `CKV_AWS_356` on the SageMaker policy. Fixed properly rather than
suppressed: only `ecr:GetAuthorizationToken` genuinely has no resource form, so
it was split out and the three layer-pull actions scoped to the managed image's
repository ARN, derived from the configured image URI.

**Verification:** 119 tests pass; all five pre-commit hooks pass.

**Notes**

Accepted as-is, unapplied. `sagemaker_training_image` is a region-specific guess
and needs checking before the first run (T-4.8) — a wrong URI fails
`create-training-job` immediately, so it is cheap to be wrong. The dependency
chain is now four deep: T-4.9 waits on T-3.8, which waits on T-2.12, which waits
on an apply. Nothing downstream of the Glue job has run against AWS.

---

### 016 — Phase 5: serverless endpoint behind a public API

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `ml/inference.py` (new), `lambda/predict/handler.py` (new), `envs/dev/{inference,api}.tf` (new), `envs/dev/{kms,variables,outputs}.tf`, `envs/dev/{versions,terraform.tfvars}`, `scripts/{promote_model,smoke_test_endpoint}.sh` (new), `scripts/train_model.sh`, `tests/test_inference.py` and `tests/test_predict_lambda.py` (new), `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
ive merged the code to main and ran terraform apply, it is all deployed. lets proceed with phase 5
```

**Output**

Asked Q-03 and Q-04 first — both are flagged in the scope as blocking, and they
change what gets built rather than a config value. **Answers: consumers outside
AWS, and Serverless Inference.** Consumers outside AWS is the expensive answer:
a SageMaker endpoint cannot be called from outside AWS at all, so it needs a
real front door rather than an invoke policy.

**`ml/inference.py`.** The managed sklearn container's default `predict_fn`
calls `model.predict()` and returns a class label — useless for something whose
entire output is a *risk score*. The handler returns `predict_proba`, accepts
three JSON shapes plus CSV, and imports the feature list from `train.py` rather
than restating it: both files ship in one source archive, so there is a single
definition of what the model consumes (D-27 again).

**The proxy.** API Gateway REST — not HTTP API, which has no native API keys —
with an API key, throttle, and a **daily quota**, because the endpoint scales
with demand and an unmetered key is an unmetered bill. A Lambda holds the IAM
identity, scoped to `sagemaker:InvokeEndpoint` on that one endpoint. It returns
400 for what the caller can fix (passing through the model's own missing-field
message), 503 with retry advice for a cold start, and a bare `prediction failed`
for anything else — an external caller should never learn a role ARN from an
error, and a test asserts none does.

**Gating.** The whole inference stack is conditional on
`approved_model_package_arn`, so phase 5 applies cleanly with no model trained
and creates nothing. Setting that ARN is the promotion step. Flagged the
consequence rather than leaving it to be discovered: because the front door is
gated on the same variable, clearing it destroys the API key and URL along with
the endpoint. Fine now, wrong once a key has been issued — **T-5.9**.

**Checkov: 14 findings, triaged individually.** Two fixed — `create_before_destroy`
on the REST API, and network isolation on the model, which is genuinely right
for a pipeline that scores in memory (behind a variable, since it is the first
thing to flip if an endpoint will not reach `InService`). The rest are
documented skips with reasons: a DLQ catches only asynchronous invocations and
API Gateway is synchronous; caching a prediction API would serve stale scores
after a model swap; KMS key policies always use `Resource "*"`, which is what
"this key" means; serverless endpoint configs have no storage volume to encrypt.
Three are real-but-deferred and got tasks (T-6.7, T-6.8, T-6.9).

Adding a **CloudWatch Logs KMS key** for the new log groups also completes the
hard half of T-6.6 — the `logs.<region>.amazonaws.com` key policy that was
deferred in entry 007 precisely because it could not be verified without
applying. It now gets exercised by the Lambda and API log groups first, which is
the right order to prove it.

**Verification run:** the inference handler was run against a **real fitted
artifact** — all four payload shapes, unseen categorical values, and each
rejection path. 35 new tests (154 total, all passing); all five pre-commit hooks
pass.

**Notes**

Accepted as-is, unapplied. One housekeeping note: fetching the new `archive`
provider without credentials required removing `.terraform/terraform.tfstate`,
so `terraform init` is needed to reconnect the S3 backend before the next apply.
The pipeline still has not run end to end — T-5.8 sits behind T-4.9, T-3.8 and
T-2.12, and the Glue job has yet to complete a single successful run.

---

### 017 — Post-apply: tracker update and a validation checklist

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/redshift_query.sh` (new), `TODO.md`, `README.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
assume all terraform apply has been succesful, update the todos and give me a list of things to check and validate and how. before creating the list, make sure to update your knwledge
```

**Output**

Re-read the repository before writing anything, which corrected a stale belief.
`git log -S` showed the user had checked off **T-2.12, T-2.13, T-2.14, T-3.6,
T-3.7, T-3.8 and T-1.11** in commit `4702822`: the Glue job has run, the crawler
has run, idempotency was verified, and a snapshot has been loaded into Redshift.
Statements in the previous two entries that the pipeline had never run end to
end were out of date. The real gap is training onward.

Also re-read `outputs.tf`, `terraform.tfvars`, `scripts/` and the job's naming so
the checklist would reference real output names rather than remembered ones.

Added **`scripts/redshift_query.sh`**: `redshift_sql.sh` applies files and
reports success, but returns no rows, so every data check would otherwise be a
three-call `execute-statement` / `describe-statement` / `get-statement-result`
incantation. Verified the result formatter against a realistic Data API
response, including a null cell.

**`TODO.md`** rewritten where it was wrong: T-4.7 and phase 5's apply marked
done; the Now section rewritten around training and deployment; the Blocked
table corrected, since T-2.12 and T-3.8 no longer block anything. Noted that
T-6.1 is only partly done — the Lambda and API log groups carry explicit
retention but exist only once inference is enabled, while Glue and SageMaker
still create theirs implicitly with no expiry.

Three verification tasks added that did not exist: **T-3.13** (a clean
`terraform plan`, which is what proves the deployment matches the commit and
that nothing was edited in the console), **T-5.11** (confirm the inference gate
works in the negative — nothing exists while the ARN is empty), and **T-X.8**
for the query helper.

The checklist itself was delivered in the reply, in five groups: infrastructure
sanity, the already-run data path, the untested remainder, cost guards, and the
known-risk items.

**Verification run:** all five pre-commit hooks pass.

**Notes**

Accepted as-is. The correction matters beyond bookkeeping: several documents
still claimed the pipeline had never run, and `README.md` and `PROJECT_SCOPE.md`
were updated to match what is actually deployed.

---

### 018 — `schema "analytics" does not exist`

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/redshift_sql.sh`, `TODO.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
i ran this command `bash scripts/redshift_query.sh "SELECT count(*) AS orders, count(DISTINCT order_id) AS ids, min(order_date) AS first, max(order_date) AS last FROM analytics.orders"` and got this response `ERROR: schema "analytics" does not exist`
```

**Output**

**Diagnosis: the migrations were never applied.** `terraform apply` does not run
them — DDL is a separate, deliberate step by design (D-38), and it was missed.
The knock-on is that **T-3.8 could not have succeeded either**:
`sql/load_orders.sql` targets `landing.orders`, which cannot exist while the
schemas do not. Both tasks had been checked off; both were reopened, and the
scope status corrected — the data path is proven as far as the processed zone,
not as far as the warehouse.

**Found a real bug in `scripts/redshift_sql.sh` while checking whether it could
have reported a false success.** If the file list came back empty — a directory
with no `.sql` files — the loop body never ran and the script printed `done` and
exited 0, having applied nothing. Reproduced it, then fixed: the script now
fails on an empty match, checks a named file exists, announces how many files it
is about to apply and to which database, and reports the count at the end
instead of a bare `done`. Whether or not that is what happened here, "applied
nothing" must never exit 0 from a script whose whole job is applying schema.

Gave the user a diagnostic sequence that distinguishes *never ran* from *ran and
failed* — listing `pg_namespace` and checking `current_database()` — rather than
assuming, plus the fix and a re-verification path.

**Verification run:** reproduced the empty-list silent success before the fix,
confirmed the guard exits 1 after. All five pre-commit hooks pass.

**Notes**

Accepted as-is. The tracker had two tasks marked done that demonstrably were
not, which is worth noting as a process point: checking a box at apply time is
not the same as verifying the thing. The validation checklist in entry 017 is
what caught it, on its first real use.

---

### 019 — Makefile and a linear README

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `Makefile` (new), `scripts/{run_etl,load_warehouse,verify}.sh` (new), `scripts/land_sample_data.sh`, `envs/dev/outputs.tf`, `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
lets update the readme with all of the steps required to install and run the entire thing. make sure to include all of the manual steps and also include a Make file that automates the deployment and the manual steps and also include separate make commands to just run a part of the process
```

**Output**

Three gaps had to be filled before a Makefile would be honest rather than a
wrapper around inline shell:

- **`scripts/run_etl.sh`** — Glue has no waiter for job runs, so the README had
  been telling people to poll by hand. It starts the job, polls to a terminal
  state, prints the resulting partitions, and warns if anything was quarantined.
- **`scripts/load_warehouse.sh`** — the load needs an `ingest_date`, which had
  to be looked up in S3 first. It defaults to the newest partition actually
  present rather than assuming today, since the ETL may have last run on a
  different day.
- **`scripts/verify.sh`** — makes the entry-017 checklist executable. Every
  check runs even after one fails, because knowing which three things are broken
  beats knowing the first.

Also added `etl_source_name` / `etl_dataset` outputs and pointed
`land_sample_data.sh` at them, so the dataset prefix is defined once in
`terraform.tfvars` instead of hardcoded per script.

**The Makefile** has a target per stage (`land`, `etl`, `migrate`, `load`,
`train`, `promote`, `smoke`), composites (`deploy`, `data`, `model`,
`bootstrap`), verification (`verify`, `query`) and local gates (`check`, `test`,
`test-fast`). `DATE=` overrides the partition. `make help` is self-documenting
from the target comments.

**Two things it deliberately does not automate**, and says so at the top of the
file:

- `apply` never passes `-auto-approve` — a developer reviews the plan (D-07).
- Promotion still means editing `approved_model_package_arn` by hand, so the
  deployed version stays a reviewed diff (D-31). `bootstrap` stops at that gate
  and prints what to do next rather than pretending to finish.

**README restructured** from a reference into a linear guide: prerequisites,
one-time setup (including creating the state bucket by hand, which cannot be
managed here), deploy, then a numbered stage-by-stage walkthrough with both the
`make` target and the underlying command. Added a table listing **every manual
step with the reason it is manual**, and gave the migrations step its own
warning — it is not part of `terraform apply`, and missing it is exactly what
produced the `schema "analytics" does not exist` error in entry 018.

**Verification run:** `make help`, `make test-fast` (123 passed), `make fmt`,
`make clean` and the `make query` guard all behave; every new script passes
`bash -n`; all five pre-commit hooks pass. Also swept the README for invisible
characters and removed a stray U+FEFF.

**Notes**

Accepted as-is. The scripts are written but unrun against AWS — `run_etl.sh`,
`load_warehouse.sh` and `verify.sh` have not yet made a real call, so their
first use is also their first test.

---

### 020 — README complete from a clean machine

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/preflight.sh` (new), `Makefile`, `requirements-dev.txt`, `README.md`, `CLAUDE.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
include steps for installing make, in the event the next developer does not have it. in short, a developer should be able to clone the repo and have all the needed steps to run all the commands and end with a successful deployment of the infrastructure and running and testing the pipeline. however do not run any of this yourself, i will run and test the accuracy and reliability of the readme
```

**Output**

Nothing was executed against AWS and no `make` target was run, per the
instruction. Verification was limited to static checks on the files themselves.

Working backwards from "clone on a clean machine" surfaced three gaps beyond the
`make` question:

1. **`pre-commit` was assumed to be on PATH.** `make install` printed a note
   telling you to go and get it, which is not setup. Moved it into
   `requirements-dev.txt` and pointed the Makefile at `venv/bin/pre-commit`, so
   `make install` now produces a working gate. `make check` fails with
   `run 'make install' first` rather than a confusing missing-binary error.
2. **`tflint` and `checkov` were never mentioned at all**, though the Terraform
   hooks shell out to them. Now listed, with the honest note that you can deploy
   and run the entire pipeline without them — they gate commits, not deploys.
3. **The AWS CLI on apt is v1**, which is not what the scripts expect. The
   Ubuntu instructions install v2 from the official archive and say why.

Added **`scripts/preflight.sh`** and `make preflight`: checks every tool, warns
on a Terraform or AWS CLI version that will not work, confirms credentials, and
checks the state bucket exists *with versioning on*. It reports everything at
once rather than failing one tool at a time.

**README** now opens the setup with per-platform toolchain installation —
macOS (`xcode-select --install` for `make` itself), Ubuntu/Debian,
Fedora/RHEL, and WSL2 for Windows — followed by clone, authenticate, create the
state bucket, and preflight. Added a **Without `make`** section mapping every
target to the command behind it, which doubles as documentation of what the
automation actually does.

**Verification run (static only):** every script passes `bash -n`; a script
compared the Makefile's targets against the README table (all 26 documented,
none stale); another checked that every `scripts/*.sh` and `sql/*.sql` path
named in the README exists, and that no script on disk goes unmentioned; a third
resolved all internal anchors and relative file links, which caught one broken
link. All five pre-commit hooks pass.

**Notes**

Accepted as-is. Fixed a quoting bug in `preflight.sh` where an apostrophe in
"README's" terminated a single-quoted `printf` — caught by adding a `bash -n`
sweep over every script rather than the one just written. The README's accuracy
end to end is untested by me by request; `make preflight` is the cheapest first
thing to try, since it is read-only.

---

### 021 — `make etl` failed on a successful run

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/{run_etl,load_warehouse,promote_model}.sh`, `tests/test_scripts.py` (new), `TODO.md`

**Prompt**

```text
i received this but i can confirm the job ran successfully [make data output ending in]
processed partitions:
                             PRE ingest_date=2026-08-27/
make: *** [etl] Error 1
```

**Output**

The Glue job did succeed. The bug was mine, in `run_etl.sh`, and it fired
**only when there were zero rejected rows** — the good case.

`aws s3 ls` exits 1 when a prefix does not exist. A clean run leaves no
`_rejected/` prefix, so under `set -euo pipefail` the assignment

```bash
REJECTS=$(aws s3 ls "s3://.../_rejected/..." 2>/dev/null | wc -l | tr -d ' ')
```

took the pipeline's non-zero status and `set -e` killed the script one line
after it printed the partitions. Reproduced it in isolation before changing
anything.

**Audited every script for the same class rather than fixing the one report**,
which found two more, both worse than the original because they made the
guidance unreachable:

- `load_warehouse.sh` — `aws s3 ls` *and* `grep` both exit 1 when there is
  nothing to find, so with no partitions the script died before printing
  "Run the ETL first: make etl".
- `promote_model.sh` — same shape; its "no PendingManualApproval versions, run
  `scripts/train_model.sh` first" message could never print.

Also hardened `run_etl.sh`'s poll loop: a transient error reading the job state
used to abort the wait on a job that was running perfectly well. It now retries
five times before giving up.

Left alone the assignments where failure genuinely *should* abort — a failed
`start-job-run`, a bad model-package ARN, a Data API call that will not execute.
`set -e` is right there; the bug is only where empty is a normal answer.

Added **`tests/test_scripts.py`** (44 tests): every script parses, is
executable and has a shebang; no `set -e` script assigns from an `aws s3 ls` or
`grep` substitution without a `||` fallback; every script the Makefile calls
exists; every target is documented and `.PHONY`; and `apply` never gains
`-auto-approve`. Confirmed the regression test fails when the bug is
reintroduced, then passes again.

That last test caught its own false positive on the first run — the Makefile
header *explains* that `-auto-approve` is deliberately absent, so the check now
strips comments and looks only at recipe lines.

**Verification run:** 198 tests pass; all five pre-commit hooks pass. Nothing
was run against AWS.

**Notes**

Accepted as-is. The ETL run itself was fine and wrote
`ingest_date=2026-08-27`, so there is no need to repeat it — `make migrate load`
picks up from there.

---

### 022 — Warehouse load timed out: enhanced VPC routing

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/terraform.tfvars`, `envs/dev/variables.tf`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
make data [... migrations applied, then]
--- sql/load_orders.sql
    FAILED
"Error": "Query #2 failed with ERROR: AwsClientException: - Failed to perform
AWS request, curlError=Connection timeout after 30002 ms"
```

**Output**

The prediction recorded when phase 3 was built — that `enhanced_vpc_routing`
would be the first suspect in an opaque timeout — was correct on the first real
load.

**Diagnosis.** The `DELETE` finished; the `INSERT ... SELECT FROM
processed_ext.takehome_orders` timed out. Only the second statement reads
outside Redshift. Checked the deployed network config rather than guessing: the
VPC has **one** egress rule (S3 prefix list, 443), **one** gateway endpoint (S3),
and no NAT. With enhanced VPC routing on, Spectrum's traffic is subject to that
security group — and resolving an external table needs the **Glue Data Catalog**,
not just S3 `GetObject`. That call had nowhere to go and hung until the 30-second
curl timeout.

**Fix:** `redshift_enhanced_vpc_routing = false`, with the reasoning inline in
`terraform.tfvars` rather than as a bare flag flip. Redshift's S3 traffic now
uses the managed network — still TLS, still scoped by the IAM role and the
bucket's TLS-only policy; it simply does not traverse our VPC. Also changed the
variable's default to `false` so a fresh environment works out of the box, and
rewrote its description to say what turning it on actually requires.

Doing it properly means interface endpoints for Glue and probably STS/KMS, at
roughly $7/month per endpoint per AZ — about $60/month across three AZs, in an
environment whose whole design premise is idling near zero. Recorded as
**T-3.14** with that arithmetic, rather than presenting it as a free security
win. D-37 was amended, since it had been written assuming the endpoint path
worked.

Noted for the user that **nothing partial landed**: the Data API runs a file's
statements in one transaction, so the failed `INSERT` rolled the `DELETE` back
with it. That was a deliberate property of the load design and it held.

Added a **Troubleshooting** section to the README covering this, the missing-
migrations error from entry 018, expired SSO tokens, the Redshift usage limit
presenting as an outage, serverless cold starts, and where to find Glue logs and
rejected rows.

**Verification run:** `terraform validate` passes; all five pre-commit hooks
pass. Nothing was run against AWS — the apply is the user's.

**Notes**

Accepted as-is. The change is a one-line tfvars edit plus a default change; it
needs `make apply` before `make load` will work. Worth noting that the guard
paid off: the variable existed specifically so this failure would be one flip to
diagnose rather than a network investigation.

---

### 023 — `Redshift endpoint is not available`

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/{redshift_sql,redshift_query,verify}.sh`, `README.md`, `TODO.md`

**Prompt**

```text
make load
--- sql/load_orders.sql
An error occurred (ValidationException) when calling the BatchExecuteStatement
operation: Redshift endpoint is not available.
```

**Output**

A different failure from the previous one, and almost certainly transient:
turning off `enhanced_vpc_routing` modifies the workgroup, and a workgroup in
`MODIFYING` rejects statements with exactly this message. It says nothing about
waiting, which is the problem.

Checked whether the scripts guarded against it — `grep -c get-workgroup` in both
returned 0. They did not. A workgroup that is `CREATING` or `MODIFYING` produced
an opaque error and the script simply died.

Added `wait_for_workgroup()` to `redshift_sql.sh` and `redshift_query.sh`: polls
until `AVAILABLE`, announces the wait once rather than per iteration, gives up
after ten minutes, and on any *other* status prints the thing worth knowing —
that the usage limit deactivates the workgroup on breach, so a sudden failure
may be a spend guard rather than an outage. Duplicated in both scripts rather
than extracted, matching how `tf_output` is already handled and keeping each
script independently runnable.

**Tested the function against all three paths** with a stubbed `aws`. The first
attempt at the MODIFYING → AVAILABLE case reported a false failure, and the
fault was in the test, not the function: `$(aws ...)` runs in a subshell, so a
counter incremented inside it never persisted and the stub returned `MODIFYING`
forever. Re-tested with a file-based counter; all three paths — immediate
availability, wait-then-proceed, and give-up — behave correctly.

Also added the workgroup status to `scripts/verify.sh`, since everything in the
warehouse section depends on it and a `MODIFYING` workgroup would otherwise
present as several unrelated failures. Extended the README's troubleshooting
with the error text and how to tell "wait" from "deactivated".

**Verification run:** every script parses; 44 script tests pass; all five
pre-commit hooks pass. Nothing was run against AWS.

**Notes**

Accepted as-is. The diagnosis is inferred rather than confirmed — the workgroup
status has not been checked directly, and the alternative (a breached usage
limit) produces the same client-side error. Both are covered: retrying now waits
automatically, and a non-transient status prints what to look at.

---

### 024 — Network isolation is not supported on Serverless Inference

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/{inference,variables}.tf`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
[terraform apply output ending in]
api error ValidationException: The network isolation is not supported for
serverless endpoint. Please disable the network isolation.
```

**Output**

My error, and an avoidable one. In entry 016 I recorded uncertainty about
whether network isolation was supported on serverless, then defaulted it to
`true` anyway — while in the same change *correctly* skipping `CKV_AWS_98` for
precisely the same "not supported on serverless" reason. Two checkov findings of
the same class, treated inconsistently; the one I "fixed" is the one that failed.

**Fix:** `endpoint_network_isolation` now defaults to `false`, with a
description saying it is an API-level incompatibility rather than a preference.
Took the `CKV_AWS_370` skip with that reason, matching how `CKV_AWS_98` was
already handled, and noting the container reaches nothing anyway — the pipeline
scores in memory and the execution role grants S3 and ECR only.

**Audited the rest of the inference stack for the same class**, so a third
failure does not surface on the next apply: checked the endpoint configuration
for `kms_key_arn`, `data_capture_config`, `async_inference_config`,
`initial_instance_count`, `instance_type`, `accelerator_type`, `vpc_config` and
`volume_size_in_gb`. The only hit was `kms_key_arn` inside the CKV_AWS_98 skip
comment; confirmed by a second grep that there is no assignment. The endpoint
configuration is otherwise clean for serverless.

Amended **D-29** to record what choosing serverless actually gives up — network
isolation and endpoint-config KMS, both rejected at the API — rather than
leaving that as two unexplained skips, and opened **T-5.13** to restore both if
the endpoint ever becomes provisioned.

**Verification run:** `terraform validate` passes; all five pre-commit hooks
pass, checkov clean with the new skip. Nothing was run against AWS.

**Notes**

Accepted as-is. The model resource was created before the failure with
isolation enabled, so the next apply replaces it — harmless, since nothing
references it yet. Re-run `make apply`.

---

### 025 — `Cannot create already existing model`

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/inference.tf`, `README.md`, `TODO.md`

**Prompt**

```text
[terraform apply output]
api error ValidationException: Cannot create already existing model
"arn:aws:sagemaker:...:model/sandbox-dev-refund-risk-f599dbef".
```

**Output**

**Cause: `create_before_destroy` propagation.** The endpoint configuration sets
it, and Terraform extends that to resources it depends on when those also need
replacing. SageMaker models are wholly immutable, so flipping
`enable_network_isolation` replaced the model — and because the replacement was
created *before* the original was destroyed, into a name derived only from the
package ARN, the name had not changed. Hence a collision with itself. The
two-minute "Still creating" was the provider retrying.

**First fix attempt was wrong and `terraform validate` caught it:**
`aws_sagemaker_model` has no `name_prefix` argument, which is the usual way to
get a distinct name per revision.

**Actual fix:** derive the name from a hash of every argument the resource sets
— the package ARN, the isolation flag and the execution role — so any change
that forces replacement also changes the name, and old and new can coexist for
the moment the swap takes. Reproduced the hashing in Python to confirm: the old
scheme yields `f599dbef`, exactly the name in the error, which validates the
diagnosis; the new scheme yields `7e028ff2`, so the swap will not collide. Made
`create_before_destroy` explicit on the model rather than leaving it implicit,
so removing it from the endpoint configuration cannot silently reintroduce this.

The version fingerprint moved to a `ModelPackageVersion` tag, since the name no
longer carries it alone — that is how a running endpoint is traced back to the
registry version it serves.

**Audited the other resources for the same latent bug.** `aws_sagemaker_endpoint`
also has a fixed name and depends on the endpoint configuration, but
`endpoint_config_name` updates in place, so the endpoint is never replaced by a
config change and no propagation reaches it. Nothing else with a fixed name sits
under a `create_before_destroy` dependency.

Added the README troubleshooting entry, including the requirement that a new
argument on the model must be added to the fingerprint, and how to clean up a
model orphaned by a failed apply.

**Verification run:** `terraform validate` passes; all five pre-commit hooks
pass. Nothing was run against AWS.

**Notes**

Accepted as-is. Whether the old `f599dbef` model becomes an orphan depends on
whether it is still in state: if it is, this apply destroys it after the swap;
if the failed apply lost it, the README now says how to remove it by hand.

---

### 026 — API Gateway stage: account-level CloudWatch Logs role

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/api.tf`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
[terraform apply — endpoint InService, then]
Error: updating API Gateway Stage: BadRequestException: CloudWatch Logs role ARN
must be set in account settings to enable logging
```

**Output**

The endpoint reached `InService` and the Lambda and integration were created, so
this is the last resource in the chain.

**Cause.** API Gateway refuses to attach a log destination to a stage unless the
*account* has a CloudWatch Logs role configured. It is a prerequisite for both
the stage's `access_log_settings` and the method settings' `logging_level`,
neither of which works without it.

**Fix.** Added an IAM role trusted by `apigateway.amazonaws.com`, an
`aws_api_gateway_account` pointing at it, and a `depends_on` from the stage so
the ordering is explicit rather than incidental. Wrote the policy out instead of
attaching `AmazonAPIGatewayPushToCloudWatchLogs`, matching how IAM is handled
everywhere else here — the managed policy grants everything on `*`, and all but
`logs:DescribeLogGroups` can be scoped to this account and region.

**The part worth flagging.** `aws_api_gateway_account` is **account-wide and
region-wide**. This stack now owns a setting that is not scoped to it:
destroying the stack disables CloudWatch logging for every API Gateway API in
the account, and a second stack configuring it would fight this one. That is a
bigger blast radius than anything else in this project, and it is only
acceptable because the account is dedicated to it. Recorded in D-30, in the
README, and as **T-5.15** — it belongs in a bootstrap configuration alongside
the state bucket before this pattern is used in a shared account.

**Verification run:** `terraform validate` passes; all five pre-commit hooks
pass, checkov clean with the split `DescribeLogGroups` statement. Nothing was
run against AWS.

**Notes**

Accepted as-is. The remaining resources after the stage — method settings, usage
plan and usage plan key — all depend on the stage and needed the same account
setting, so this should be the last blocker in the apply.

---

### 027 — Pipeline green end to end, and an information leak it exposed

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `lambda/predict/handler.py`, `envs/dev/{api,variables}.tf`, `scripts/smoke_test_endpoint.sh`, `tests/{test_predict_lambda,test_train}.py`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
make smoke
[... all checks passed, including]
  ok    missing required field -> 400
        {"error": "Received server error (500) from model with message \"<!DOCTYPE HTML ...
        See https://...console.aws.amazon.com/cloudwatch/... in account 823878989845 ..."}
```

**Output**

The pipeline is green end to end — raw CSV through Glue, Parquet, Redshift,
training, the registry, the endpoint, and a public API call returning a
calibrated probability. Every smoke check passed.

**One of those passes was hiding a real defect.** The `missing required field`
case returned the right status code and a body containing an HTML error page,
the **AWS account id**, the endpoint name and a CloudWatch console URL — to an
unauthenticated external caller.

Two mistakes of mine met here. The handler passed `ModelError` text through on
the reasoning, recorded in entry 016, that "its message names the missing
fields, so it is worth passing back" — but SageMaker wraps the container's
response, and the wrapper is what carries the account id. And the smoke test
asserted only the status code, so it reported `ok` on a leaking response.

**Fixes:**

- **Validate at the edge.** The proxy now checks required fields itself, so a
  bad request gets a clean 400 naming the missing fields and never wakes the
  endpoint. The field list comes from Terraform (`predict_required_fields`) and
  a test asserts it matches `train.FEATURES` — the same drift guard already used
  between the training view and the training script.
- **Never echo `ModelError`.** The detail is logged; the caller gets a generic
  message.
- **Assert bodies, not status codes.** The smoke test now fails any response
  containing the account id, the endpoint name, a console URL, `DOCTYPE` or
  `Traceback`.

Added regression tests for all three, including one that feeds the proxy the
exact wrapper text from this run and asserts none of its four identifiers
survives into the response body.

**Verification run:** 201 tests pass; all five pre-commit hooks pass. Nothing
was run against AWS — the redeploy is the user's.

**Notes**

Accepted as-is. Worth stating plainly: a green test suite reported this as
working. It took reading the output to notice, which is an argument for
assertions that check what was actually returned rather than that something was
returned. The endpoint needs `make apply` to pick up the new Lambda before
`make smoke` will show the corrected behaviour.

---

### 028 — Leak fix confirmed; tracker reconciled

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `TODO.md`, `README.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
make smoke
[... all checks passed, with]
  ok    missing required field -> 400
        {"error": "instance 0 is missing required fields: ['channel', 'category',
         'quantity', 'unit_price_usd', 'discount_pct', 'order_dow']"}
```

**Output**

The leak is closed. The missing-field case now returns a message that names the
fields and contains nothing from SageMaker's error wrapper — no account id, no
console URL, no HTML.

Reconciled the tracker, which had drifted behind reality. **T-1.10, T-3.7,
T-3.8, T-4.7, T-4.9 and T-4.10 were still marked open despite having
demonstrably happened** — the endpoint serves a model trained from
`ml.orders_training`, which reads through `analytics.orders` to
`landing.orders`, so training could not have produced a working model unless
data had landed, the migrations had applied and the warehouse had been loaded.
Closed them with that reasoning recorded rather than silently ticking boxes.

T-3.7 and T-3.8 in particular had been *reopened* in entry 018 after the
`schema "analytics" does not exist` failure; they are now genuinely done.

Rewrote the Now section, which still described work already finished, around
what actually remains: verifying the two warehouse properties that need a second
load to observe, the absence of any budget alarm now that everything is
deployed and idling, and the two pieces of deliberate temporary state
(T-2.10, T-2.16). Updated the status blocks in the README and the scope, both of
which still said training had not run.

**Progress: 71 done, 35 open.**

**Verification run:** all five pre-commit hooks pass. Nothing was run against
AWS.

**Notes**

Accepted as-is. The highest-value remaining item is not a feature: phase 6 has
not started, so a fully deployed environment has no budget alarm and no failure
alerting. The Redshift usage limit is the only automatic guard and it covers one
service.

---

### 029 — Proposed transformations, and removing row counts

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `docs/proposed-transformations.md` (new), `docs/dataset-takehome-orders.md`, `tests/test_transform.py`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`, `sql/migrations/005_ml_training_view.sql`, `scripts/run_etl.sh`

**Prompt**

```text
where is the list of transformations? and there should be no mentions of row
counts anywhere as the row counts may vary
```

**Output**

Two corrections, both fair. The previous reply mixed findings with
recommendations instead of producing a list, and row counts were scattered
through the docs from when the sample file was tiny.

**The row-count problem was not only prose — two tests were failing.**
`test_transform.py` asserted `evaluated.count() == 19` and an exact set of
dimension values, both of which broke when the source file was replaced with a
much larger one. Rewrote them to assert *properties* instead: no row is silently
dropped, every reject carries a non-empty reason, the reject rate is not
wholesale, and cleaned dimension values are subsets of the canonical set with
every value already normalised. Those hold whatever the file contains.

Removed counts from `README.md`, `PROJECT_SCOPE.md`,
`005_ml_training_view.sql`, `run_etl.sh` and throughout the dataset doc, and
restated the dataset doc in terms of properties, with a note at the top saying
explicitly that nothing depends on file size.

Two claims in that doc were not merely stale but **wrong** against the current
file, and were corrected rather than reworded: `order_id` is no longer unique,
and slash-format dates are no longer unambiguous — the note that said "no
slash-format date is ambiguous ... which is the only reason month-first parsing
is safe" now says the opposite, because the condition it depended on has failed.
The SKU note was also wrong in kind: it described one conflicting SKU, where in
fact effectively every SKU maps to many products and categories, which makes the
column useless as a key rather than merely untidy.

**Wrote `docs/proposed-transformations.md`** — 16 candidates with stable
`TR-##` ids, an index table with an empty Decision column, a detail block per
item (column, current behaviour, problem, proposal, decision), and an empty
section for the reviewer to append to. Verified every id in the table has a
detail block and vice versa. Cross-linked from the README, the dataset doc and
`TODO.md` (T-2.19) so it is not a stray file.

Nothing was implemented — the request was for a list to review.

**Verification run:** 202 tests pass, including the two rewritten ones; all five
pre-commit hooks pass; no row counts remain outside this log; all relative links
resolve.

**Notes**

Accepted as-is. Worth recording that the tests hardcoding a row count is the
same failure as the docs doing it — an assertion tied to the size of a sample
rather than to a property that should hold. The rewritten ones would have
survived the file being replaced.

---

### 030 — Transformations approved and implemented

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `glue/jobs/raw_to_processed.py`, `sql/` (003, 005, 006, load), `ml/train.py`, `envs/dev/variables.tf`, `tests/{test_transform,test_spec,test_train,test_inference,test_predict_lambda}.py`, `docs/{proposed-transformations,dataset-takehome-orders}.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
i approve your recommendations. additionally lets make sure we are standardizing
the order_ts to a valid linux epoch [...] remove leading and training whitespaces
[...] default any missing integer in shipping_days and quantity to a null.
default any missing float in unit_price_usd and discount_pct to NaN. reject
duplicate rows where all fields match. lower case all text. Clean unit_price_usd
removing the `$` symbol
```

**Output**

Implemented TR-01–TR-15 and all seven additions. Two of the additions were
already in place (trimming, `$` stripping) and were verified rather than
rebuilt.

**The cleaning rules collapsed from five to three.** "Lower case all text" makes
`code`, `enum` and `text` identical, so they became one `text` rule. Identifiers
are lowercased too.

**Two conflicts that needed resolving rather than implementing literally:**

1. **NaN and `decimal` are mutually exclusive.** Decimal types cannot represent
   NaN, so `unit_price_usd` moved from `decimal(12,2)` to `double`. That trades
   exactness on monetary sums, and the test asserting decimal was rewritten to
   state the trade rather than deleted.
2. **NaN poisons arithmetic in a way NULL does not** — a real bug I introduced
   and then caught: `coalesce` handles NULL but not NaN, so one absent discount
   turned every derived amount on that row into NaN. Fixed with `nanvl`, and
   verified across four cases. An absent *price* is deliberately left to
   propagate: an amount computed from an unknown price is genuinely unknown.

**Exact-duplicate rejection is separate from key deduplication**, and ordered
before it. A row identical in every field needs no adjudication; a repeated key
with differing values is a genuine conflict, and one reason should not mask the
other. On the current file this turned out to matter for classification rather
than count — every repeated `order_id` proved to be a full-row duplicate, so
there are no real key conflicts at all.

**Ran the new spec against the real file before touching anything downstream.**
The reject rate fell from 4.5% to 3.45% (TR-05 stopped discarding orders with an
unknown customer), and the remaining rejects are negative quantities and exact
duplicates. Verified epoch round-trips, midnight for date-only values, region
mapping, lowercasing, NULL/NaN defaults, the derived amounts and
`customer_order_seq`.

**Downstream:** `landing.orders` needed `order_ts BIGINT`, `DOUBLE PRECISION`
money, nullable `customer_id` and `quantity`, and eight new columns. Since
`CREATE TABLE IF NOT EXISTS` cannot alter an existing table, added
`006_rebuild_landing_orders.sql` — a one-time drop and rebuild, safe because the
table is a copy of the processed zone. It necessarily duplicates 003–005, which
is tracked for deletion as T-3.15.

**TR-15 changed the model**: `shipping_days` added to the training view,
`FEATURES`, and the Terraform-declared API contract — the existing drift test
confirmed all three agree.

**Two items were deliberately not implemented.** TR-16 (the ambiguous date
convention) and TR-08 (the digital-shipping rule) both need an answer from
whoever owns the feed. Adding a rule to TR-08 before the column's meaning is
settled would encode a guess as a constraint.

**Verification run:** 211 tests pass. Sixteen failed initially, all from the
deliberate changes; several fixtures broke on the new identifier patterns, and
four tests that named specific rows from the old file were rewritten to assert
properties instead. All five pre-commit hooks pass.

**Notes**

Accepted as-is, unapplied. Deploying needs `make apply` (new job script), then
`make migrate` for the rebuild migration, then `make etl load` — the warehouse
must be reloaded because the processed schema changed. `--max_reject_pct` should
be re-derived now that the rate has moved (T-2.20).

---

### 031 — Migration ordering: a rebuild cannot follow its dependents

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `sql/rebuild_landing_orders.sql` (new, replacing `sql/migrations/006_*`), `Makefile`, `tests/test_sql.py` (new), `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
{"Error": "Query #1 failed with ERROR: column \"order_dow\" does not exist in orders",
 "Sql": "CREATE OR REPLACE VIEW ml.orders_training AS ... order_dow ..."}
```

**Output**

My ordering error, from the previous entry. The rebuild was numbered `006`, but
`005` builds a view over the columns the rebuild creates — so `005` ran first and
failed, and `006` was never reached. **A rebuild cannot sit after the
definitions that depend on it.** The previous entry noted the file "duplicates
003–005 by necessity ... because migrations are ordered"; the necessity was the
signal that it did not belong in the sequence at all.

**Fix: moved it out of `sql/migrations/` entirely**, to
`sql/rebuild_landing_orders.sql`, alongside `load_orders.sql` and
`unload_training_set.sql` — the existing convention for operations run
deliberately rather than as part of a re-runnable sequence.

That also removed the duplication rather than merely tracking it. The file is now
a single `DROP TABLE ... CASCADE`: the migrations recreate the table and both
views from their own definitions, so there is no second copy of the DDL to keep
in step. Added `make rebuild`, which drops, re-migrates and reloads in order.

Leaving it in the sequence had a second problem worth stating: a `DROP` that runs
on every `make migrate` would silently empty the warehouse on a routine
re-application.

**Added `tests/test_sql.py`** (27 tests) encoding the rule and several
neighbouring ones: migrations are numbered and contiguous; **no migration
contains a `DROP`**; every migration statement is `IF NOT EXISTS` or
`OR REPLACE` so the directory can be re-applied; every `${placeholder}` is one
the runner can actually supply; the `INSERT` column list matches the table
definition exactly; and the training view reads `analytics.orders` rather than
the history table.

**Verified the two most valuable of those fail on the real bugs** — restoring a
`DROP` migration fails the ordering test, and dropping a column from the load's
list fails the agreement test — then restored both.

**Verification run:** 238 tests pass; all five pre-commit hooks pass. Nothing was
run against AWS.

**Notes**

Accepted as-is. Recovery is `make rebuild`. The partially-applied state is
harmless: 003 and 004 succeeded as no-ops against the old schema, and the drop
clears all of it.

---

### 032 — The rebuild rebuilt the warehouse but not the data it reads

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `Makefile`, `scripts/{load_warehouse,reset_catalog_table}.sh`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
{"Error": "Query #2 failed with ERROR: column \"order_year\" does not exist in
 takehome_orders", ... "INSERT INTO landing.orders ... FROM processed_ext.takehome_orders"}
```

**Output**

The previous fix was incomplete. `make rebuild` dropped and rebuilt
`landing.orders` correctly — the error has moved from `orders` to
`takehome_orders`, the *external* table — but the processed Parquet in S3 was
still written by the old job, so the columns the load wants do not exist there
yet. The warehouse was rebuilt; the data it reads was not.

Three changes:

**`make rebuild` now runs the whole chain in order** — reset the catalog, re-run
the ETL, drop, migrate, load — and prints a reminder that `make apply` must come
first if the job script changed, since otherwise the ETL rewrites the old shape.

**`make load` now checks before it starts.** It reads `svv_external_columns`,
compares against the column list parsed out of `load_orders.sql`, and reports
every missing column at once with the fix, instead of Redshift naming one at a
time across successive failed runs. Verified the logic against a simulated old
schema — it names exactly the eight new columns — and against the current one,
where it reports nothing.

**Added `scripts/reset_catalog_table.sh` and `make reset-catalog`,** for a risk
that had not surfaced yet but would have been worse than this failure. The Glue
sink adds columns to the catalog reliably; changing a column's *type* is less
dependable, and this change altered two — `order_ts` to an epoch and
`unit_price_usd` to a double. A stale catalog type is not an error but a silent
misread: an epoch interpreted as a timestamp is garbage that loads cleanly.
Deleting the table forces the next run to recreate it from the data. It removes
metadata only.

That risk exists because the processed catalog table is still sink-managed
rather than declared in Terraform — the temporary state T-2.10 already tracks.
Recorded as a concrete consequence in the scope and as T-2.21.

**Verification run:** 242 tests pass; all five pre-commit hooks pass. Nothing was
run against AWS.

**Notes**

Accepted as-is. Recovery is `make apply` then `make rebuild`. Two failures in a
row came from the same root: a schema change has to propagate through catalog,
Parquet, table and views in order, and I fixed one link at a time instead of
tracing the chain.

---

### 033 — README audit

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `README.md`, `tests/test_train.py`

**Prompt**

```text
is the readme up to date?
```

**Output**

No, in three places. Audited it against the code rather than reading it over.

**The worked `curl` example was broken.** It omitted `shipping_days`, which
TR-15 made a required field, so anyone copying it would have got a 400. A stale
example is the worst kind of documentation rot: it looks authoritative and fails
on first use.

**A stale metric and row count** — "on 19 sample rows this scores an ROC AUC
around 0.54" survived the earlier sweep for counts, and both halves were wrong
after the dataset was replaced. Rewritten to describe what the training script
reports rather than quoting a number that goes out of date on the next run.

**The transform section predated the revision**, still describing the job in
terms that no longer matched: no mention of epoch timestamps, lowercasing, or
the NULL/NaN defaults. Replaced with a short summary of what actually happens to
a row, pointing at the dataset doc for the full contract.

**Added a drift test for the example.** The feature contract spans four places —
the training view, `train.py`, the Terraform-declared API contract, and the
README's example. The first three had drift tests, which is why they stayed in
step; the example had none, which is why it did not. The test parses the
README's payload and asserts it carries every feature. Confirmed it fails when
the field is removed again.

**Then audited the rest mechanically** rather than by eye: internal anchors,
relative file links, every script and SQL file named, every make target
documented, and residual hard numbers. All clean; the two numeric hits are the
Terraform version pin and a task id.

**Verification run:** 243 tests pass; all five pre-commit hooks pass.

**Notes**

Accepted as-is. The pattern is worth noting: every part of the feature contract
with a test stayed correct, and the one part without a test went stale within a
turn of being written. Documentation that can be checked mechanically should be.

---

### 034 — `make promote` records the approved ARN

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/promote_model.sh`, `envs/dev/terraform.tfvars`, `Makefile`, `tests/test_scripts.py`, `README.md`, `PROJECT_SCOPE.md`

**Prompt**

```text
when runnin make model. if the user selects to approve the model, update the
variable in terraform.tfvars
```

**Output**

Implemented, and **revised D-31 rather than leaving the decision contradicting
the code**. D-31 had recorded the hand-edit as part of the design: "promotion
means editing terraform.tfvars by hand, so the deployed version stays a reviewed
diff".

The property that decision protects is unchanged. The served version still lives
in version control and still reaches the endpoint only through a reviewed diff
and a manual apply. What is given up — a person typing an ARN — was never the
safeguard; it was a source of error, since a truncated or stale ARN deploys the
wrong model and looks exactly like the right one. Recorded as a dated revision
with that reasoning.

On approval the script rewrites the assignment with `sed`, using `|` as the
delimiter because an ARN contains slashes but never a pipe, then prints
`git diff` of the file so the change is visible before `make plan`. It refuses
rather than appending if the assignment is absent, since guessing where to put
it in a config file is worse than stopping.

**A first attempt broke on nested heredocs** — embedding a Python heredoc
terminated by `PY` inside another one closed the outer early. Checked that
`promote_model.sh` was undamaged before retrying, then dropped the embedded
Python for `sed`, which needs no nesting.

**Tested the edit on copies rather than the real file**, across the cases that
could corrupt it: an empty existing value, a populated one, a file with no such
assignment, and a check that the result parses back. Replacing an ARN changes
that line and nothing else — same line count, zero other differences — and the
missing-assignment case refuses instead of appending.

Added a test pinning the shape of the assignment, since the script's `sed`
pattern depends on it and a reformat would turn a promotion into a refusal.

**Verification run:** 244 tests pass; all five pre-commit hooks pass. Nothing was
run against AWS.

**Notes**

Accepted as-is. `make model` still stops after approval by design — it records
the ARN, it does not apply.

---

### 035 — Seed the sample data, and document what Terraform cannot do

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `envs/dev/{storage,variables,outputs}.tf`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
lets push this artifact `data/dpe_interview_takehome_data.csv` into the
sandbox-dev-raw-data-platform bucket after the bucket is created so that the
pipeline works without any intervention. additionally add on the readme any
manual dependencies on aws that terraform cannot complete
```

**Output**

**Seeding the raw zone from Terraform crosses a line D-38 draws** — Terraform
owns infrastructure, not data in S3 — so it was implemented as a scoped,
recorded exception rather than slipped in. It is acceptable only because the
file is a committed fixture. Managing a real feed this way would make the raw
zone, the single copy everything else is regenerable from, a function of a plan:
deleted on destroy, restored on drift. It sits behind `seed_sample_data`, and
**T-6.10** requires that to be false once a real source exists.

Verified the seeded key resolves to exactly the prefix the job reads and the one
`make land` writes, so the two cannot disagree. Also documented the consequence
that follows from Terraform owning that object: replacing that exact key by hand
is reverted on the next apply.

**The manual-dependencies section** lists what sits outside any configuration,
with the symptom each produces rather than just the requirement — the state
bucket, credentials, **service quotas** (a new account can have a quota of zero
for an instance family, which surfaces as `ResourceLimitExceeded` from
`make train`), Cost Explorer needing enablement before a budget reports
anything, billing access for non-root principals, three usable availability
zones for Redshift Serverless, and global S3 bucket-name uniqueness given that
the suffix here is the owner tag rather than the account id. Included the
`service-quotas` commands to check the two that matter before a first deploy,
and repeated that `aws_api_gateway_account` is account-wide.

**Fixed a broken anchor and removed the cause.** Renaming a heading left a stale
link; while fixing it, two anchor targets contained em dashes, which renderers
slug inconsistently. Rather than guess the right number of hyphens, the
punctuation was dropped from both headings so the anchors are unambiguous.

**Verification run:** 244 tests pass; all five pre-commit hooks pass, checkov
clean with the new object. All anchors and relative links resolve. Nothing was
run against AWS.

**Notes**

Accepted as-is. On the next apply the sample file appears in the raw zone, so a
fresh environment goes straight from `make deploy` to `make etl`. The quota and
Cost Explorer items are the ones most likely to matter in an unfamiliar account,
and neither can be resolved by anything in this repository.

---

### 036 — Smoke test drift, and the real skew it exposed

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `ml/features.py` (new), `ml/{train,inference}.py`, `scripts/{smoke_test_endpoint,train_model}.sh`, `envs/dev/outputs.tf`, `tests/{test_train,test_inference}.py`, `README.md`, `PROJECT_SCOPE.md`, `TODO.md`

**Prompt**

```text
[terraform outputs, then]
  FAIL  valid single order -> 400 (expected 200)
        {"error": "instance 0 is missing required fields: ['shipping_days']"}
```

**Output**

The immediate cause was drift I had just written a test for and applied too
narrowly. Adding `shipping_days` in entry 030 required updating five places; I
fixed four and covered only the README with a drift test. The smoke test was the
fifth, and it went stale within two turns — the same pattern noted in entry 033,
repeating because the lesson was applied to one file instead of the class.

The payloads were also repeated inline per case, so the fix now defines them
once and every case varies only what it tests.

**Reading those payloads surfaced something worse.** They sent `"EMEA"`, but the
ETL lowercases every string column, so the model learned `"emea"`. Nothing
normalised the inference input, so `handle_unknown="ignore"` encoded it as all
zeros — **not an error, a quietly worse prediction**. That is real
training/serving skew, and precisely the failure D-27 exists to prevent. It had
been sitting in every prediction the endpoint had served.

Fixed by moving the ETL's text cleaning into the pipeline as its first step, so
both paths share it by construction rather than by discipline. Confirmed a
mixed-case request now scores identically, and added that as an assertion in
both the unit tests and the smoke test.

**That fix then exposed a genuine deployment bug, via a test failure that looked
like a fixture problem.** `PicklingError: Can't pickle normalise_text`. SageMaker
script mode runs the training entry point as `__main__`, so a transform function
defined in `train.py` pickles as `__main__.normalise_text` — a name that does not
resolve in the inference container, where `inference.py` is the entry point. The
model would have trained successfully and failed to load.

Extracted the contract and the cleaning into `ml/features.py`, imported by both,
so the reference resolves either way, and added it to the training archive.
**Verified against the real path** rather than trusting the unit tests: trained
by running `train.py` as `__main__`, then loaded the artifact from a separate
process through `inference.py`. It scores, and the pickle references `features`
rather than `__main__`.

Also added a `predict_required_fields` output so the smoke test fails with one
clear message when it falls behind, rather than three confusing 400s.

**Verification run:** 247 tests pass; all five pre-commit hooks pass; README
anchors and links resolve.

**Notes**

Accepted as-is. `make apply` then `make model` are needed — the deployed model
predates the normalisation fix, so until it is retrained the endpoint still
mishandles mixed-case input.

---

### 037 — Why first-pass failures keep happening

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/{run_etl,verify}.sh`, `README.md`, `TODO.md`

**Prompt**

```text
these errors keep happening on the first pass. is there a step we are missing?
or something thats configured incorrectly [smoke test now fully passing]
```

**Output**

The smoke test passes, including the mixed-case check that proves the skew fix
reached the endpoint.

Answered the question by categorising all fourteen failures that reached a real
apply or run this session, rather than generalising:

| Cause | Count |
|---|---|
| AWS API behaviour only knowable by calling AWS | 5 |
| My logic errors | 2 |
| Drift between duplicated definitions | 2 |
| Design gaps | 2 |
| Terraform semantics, runtime shape, stale artefact | 3 |

**Eight of fourteen were catchable locally in principle.** That is the honest
answer: nothing is misconfigured, but the first apply has been serving as the
first integration test, and roughly half of what it caught did not need AWS to
find. Each one produced a test afterwards, which is why the suite went from 96
to 247 — but reactively, one class at a time.

**One systemic gap was still open, and closing it was the concrete "missing
step".** Nothing verified that what is deployed matches the working tree. Editing
the job script and running the job without applying executes the *previous*
version, and the symptom appears later and elsewhere — which is exactly what the
stale-processed-schema failure was. `run_etl.sh` now compares the deployed script
against the local one and refuses, and `verify.sh` reports it.

Added a **"Why a first apply often fails"** section to the README stating plainly
what cannot be validated without AWS, what each guard does catch, and the
ordering trap: a transform change must propagate through job script, Parquet,
catalog, external table, landing table, views, model and API contract in that
order, and fixing one link at a time produces a run of unrelated-looking errors.

**Verification run:** 247 tests pass; all five pre-commit hooks pass; README
anchors resolve.

**Notes**

Accepted as-is. Two of the five AWS-behaviour failures were ones I had flagged
uncertainty about and then defaulted to the riskier setting anyway — network
isolation and enhanced VPC routing. That is not a tooling gap; the rule taken
from it is that flagged uncertainty should default to off.

---

### 038 — `make data` or `make rebuild` on a clean account

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/land_sample_data.sh`, `Makefile`, `README.md`

**Prompt**

```text
after runing make apply, on a clean aws account, shouw i run make rebuild or
make data?
```

**Output**

`make data`. Traced both rather than answering from memory: `rebuild` adds a
catalog delete and a `DROP TABLE IF EXISTS`, and both are no-ops on a clean
account — so it would work, but it is the wrong tool. It exists for when a
transform change has left artefacts written by an older version of the job.

**Checking the answer turned up a small real problem.** `make data` starts with
`make land`, and `terraform apply` now seeds that same object. Landing it again
with `aws s3 cp` replaces a Terraform-managed object and drops the tags
Terraform set, which would show as drift on the next plan. `land` now compares
content hashes and skips when they already match, so the seeded object is left
alone.

That the question needed asking at all was the signal that the target help was
unclear, so both were rewritten: `data` now reads "run the data path on a fresh
environment — start here after `make deploy`", and `rebuild` "re-run everything
after a *transform change*". The README says the same in the pipeline section,
and the quick start is now labelled as the whole clean-account path in order.

**Verification run:** 247 tests pass; all five pre-commit hooks pass.

**Notes**

Accepted as-is. A question about which command to run is usually a documentation
defect rather than a user error, and in this case it also surfaced a drift bug.

---

### 039 — Smoke test labels described the wrong thing

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/smoke_test_endpoint.sh`, `tests/test_train.py`, `README.md`

**Prompt**

```text
if this is a passing smoke test then the descriptions are misleading. also, it
is not returning the result of the api endpoint being called
```

**Output**

Both correct, and both real.

**The labels described inputs, not expectations,** so a reader could not tell
whether a `400` was the point or the problem. Rewritten as statements of
behaviour — "rejects an empty instances list" rather than "empty instances" —
so `ok` reads as "it did that".

**One label was outright wrong.** `"missing required field"` sent
`{"region":"emea"}`, which omits seven. Split into two cases: an otherwise
complete order with exactly one field removed, which is the realistic mistake
and now genuinely matches its label, and a separate almost-empty payload.

**Two checks discarded the response.** The mixed-case comparison sent both
requests to `/dev/null` and printed only a verdict, and the API-key check used
`curl -o /dev/null`, so neither showed what came back. Both now print the
bodies — the mixed-case one prints both, so "identical" is verifiable rather
than asserted.

**Checking this exposed a hole in a test I wrote two entries ago.** The drift
test matches inline `{"instances":[{...}]}` blocks, but refactoring the smoke
payloads into `ORDER=` and `OTHER=` variables moved them outside that pattern —
so the test written to prevent staleness could no longer see the payload most
likely to go stale. Extended it to read the shell assignments, and confirmed it
fails when `$ORDER` alone is broken.

**Verification run:** 247 tests pass; all five pre-commit hooks pass. Nothing was
run against AWS.

**Notes**

Accepted as-is. Third time a fix has been applied narrowly enough to leave the
same class open elsewhere: the drift test covered the README, then the smoke
test, and needed extending again the moment that file was refactored.

---

### 040 — An unmissable verdict

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/{smoke_test_endpoint,verify}.sh`, `tests/test_scripts.py`

**Prompt**

```text
add a clear indication that the user can understand this was successful
```

**Output**

Both scripts ended on a single unstyled line — `all checks passed` for the smoke
test, a bold count for `verify` — easy to lose under a screen of JSON, which is
exactly where the answer matters most.

Both now close on a bounded, coloured verdict stating the count and what it
means:

```
────────────────────────────────────────────────────────────────
  PASSED — 9 of 9 checks

  The public endpoint is live and serving predictions.
  Reachable from outside AWS, over HTTPS, with an API key:
    https://…/dev/predict
────────────────────────────────────────────────────────────────
```

The failure form is equally prominent, goes to stderr, and says where to look —
for the smoke test, that a 5xx implicates the endpoint or proxy while a wrong
4xx implicates the request contract; for `verify`, that the list should be
worked in order because a stale deployment or missing schema makes everything
after it fail too.

Required adding pass counters: the smoke test only tracked a failure flag, so it
could not say "9 of 9". Both hand-rolled checks — mixed case and the API key —
had to be counted alongside those going through `check()`, or the total would
have quietly under-reported.

Rendered both outcomes before finishing, rather than assuming the escape codes
and the `printf` formats were right.

Added three tests covering both scripts: each states a verdict for success *and*
failure, each reports a count, and each exits non-zero when it fails. That last
one matters most — a script that prints "FAILED" and exits 0 would pass in
`make`.

**Verification run:** 253 tests pass; all five pre-commit hooks pass.

**Notes**

Accepted as-is.

---

### 041 — Every request 403, and a check that passed anyway

- **Date:** 2026-08-27
- **Model:** Claude Opus 5 (`claude-opus-5[1m]`)
- **Tool:** Claude Code CLI
- **Files touched:** `scripts/smoke_test_endpoint.sh`, `envs/dev/outputs.tf`, `tests/test_scripts.py`, `README.md`

**Prompt**

```text
this was from a fresh deploy [make smoke — 7 of 9 checks FAIL with
403 {"message":"Forbidden"}]
```

**Output**

Two problems, one of them mine and worse than the symptom.

**The mixed-case check reported `ok` while every request was being refused.** It
asserted that two responses were *equal*, and two identical `403 Forbidden`
bodies are equal. A check meant to prove the model normalises its input passed
without a prediction existing. It now requires a prediction before comparing —
otherwise it fails and says nothing was compared.

That is the more serious finding: the run was reported as 7 of 9 failures when
it was really 8 of 9, and the passing one was passing for no reason.

**The script never checked that it had a key.** `API_KEY=$(aws apigateway
get-api-key ...)` was used unguarded, so an unreadable key is sent as an empty
header and every check returns 403 — nine failures describing one problem, none
of them naming it. It now fails immediately if the key cannot be read, is
disabled, or is attached to no usage plan covering the stage. That last case is
worth naming because API Gateway refuses such a key exactly as it refuses no key
at all.

**Added a warm-up retry on 403.** A usage-plan key association is not instant on
a fresh deploy and reads as `Forbidden` until it propagates, which is
indistinguishable from a misconfiguration in a single attempt. The warm-up now
retries, and says so explicitly if 403 persists, since at that point it is not
propagation.

Added regression tests for both: the key must be validated before the first
request, and comparison checks must require a successful response rather than
agreement alone.

**Verification run:** 253 tests pass; all five pre-commit hooks pass. Nothing was
run against AWS, so whether this particular 403 was propagation or configuration
is untested — the script now distinguishes them.

**Notes**

Accepted as-is. Re-run `make smoke`: if it was propagation the retry absorbs it,
and if it was not, the preflight names which of the three causes it is instead
of reporting seven identical failures.
