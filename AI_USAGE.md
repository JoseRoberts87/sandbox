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
