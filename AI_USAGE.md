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
