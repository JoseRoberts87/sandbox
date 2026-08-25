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
