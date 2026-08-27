# Dataset: `takehome/orders`

Order lines from the take-home dataset. The schema and every cleaning rule are
declared in `DATASET_SPECS["takehome/orders"]` in
[`glue/jobs/raw_to_processed.py`](../glue/jobs/raw_to_processed.py) — this
document explains the *why*; the job is the source of truth for the *what*.

**Source file:** `data/dpe_interview_takehome_data.csv` — 19 rows, 13 columns,
CSV with header.

## Landing it

```bash
RAW=$(terraform -chdir=envs/dev output -raw raw_bucket_name)

aws s3 cp data/dpe_interview_takehome_data.csv \
  "s3://$RAW/takehome/orders/ingest_date=2026-08-26/dpe_interview_takehome_data.csv"
```

## Schema

| Column | Source | Target | Cleaning | Constraints |
|---|---|---|---|---|
| `order_id` | string | `string` | code | required, primary key |
| `order_ts` | string, 4 formats | `timestamp` | trim | required |
| `customer_id` | string | `string` | code | required |
| `region` | string | `string` | code | — |
| `channel` | string | `string` | enum | one of online, partner, retail, wholesale |
| `product_sku` | string | `string` | code | required |
| `product_name` | string | `string` | text | — |
| `category` | string | `string` | enum | — |
| `quantity` | string | `int` | trim | required, >= 1 |
| `unit_price_usd` | string, may carry `$` | `decimal(12,2)` | money | required, >= 0 |
| `discount_pct` | string | `double` | trim | 0 – 1 |
| `order_status` | string | `string` | enum | one of cancelled, completed, pending, refunded |
| `shipping_days` | string, may be blank | `int` | trim | >= 0, **nullable** |

Cleaning rules:

| Rule | Applied to | Effect |
|---|---|---|
| `code` | identifiers, `region` | trim, collapse internal whitespace, UPPERCASE |
| `enum` | closed sets and grouping keys | trim, collapse whitespace, lowercase |
| `text` | `product_name` | trim, collapse whitespace, case preserved |
| `money` | `unit_price_usd` | strip currency symbols and separators |
| `trim` | numerics, `order_ts` | trim only |

Identifiers are uppercased because they are codes; grouping dimensions are
lowercased because they are join keys where case must not create duplicates;
display text keeps its case because nothing joins on it.

## What was wrong with the source data

Profiled before writing the spec. Every item below is real, and is why the job
declares types rather than inferring them:

| Problem | Detail |
|---|---|
| **Four timestamp formats in one column** | `yyyy-MM-dd HH:mm:ss` (10 rows), `MM/dd/yyyy` (4), `dd-MMM-yyyy` (3), `yyyy-MM-dd'T'HH:mm:ss'Z'` (2) |
| **Currency symbol in a numeric column** | `$159.28` in `unit_price_usd`; every other value is bare |
| **Case variants** | `region` 7 distinct → 4 real values (`North America`, `NORTH AMERICA`, `emea`, `EMEA`…); `channel` 6 → 4 |
| **Leading/trailing whitespace** | `category` 10 distinct → 6 real values (`  Puzzles `, `  Accessories `…) |
| **Blank numeric** | one blank `shipping_days` |
| **Inconsistent SKU mapping** | `SKU-1067` maps to both *Paint Set* (miniatures) and *Dungeon Delve* (board games) |

`order_id` is unique across all 19 rows, and no slash-format date is ambiguous —
every one has a day component greater than 12, which is the only reason
month-first parsing is safe to assume here. **If a future file contains
`03/04/2025`, that assumption breaks silently.** Worth confirming with the source
system rather than relying on the current data.

The SKU conflict is a cross-row problem that a row-level transform cannot fix.
The job logs it as a warning and loads the rows unchanged; resolving it is a
source-system question.

## Derived columns

| Column | Definition |
|---|---|
| `order_date` | `to_date(order_ts)` |
| `gross_amount_usd` | `quantity * unit_price_usd` |
| `net_amount_usd` | `quantity * unit_price_usd * (1 - discount_pct)`, rounded to 2dp |

**Assumption:** `discount_pct` is a fraction (observed range 0 – 0.25, not
0 – 100) applied to the whole line. Unconfirmed — if discounts are per-unit or
already reflected in `unit_price_usd`, `net_amount_usd` is wrong and both the
definition and this note need updating.

Plus the lineage columns every processed table carries: `ingest_date`,
`etl_source_file`, `etl_processed_at`, `etl_job_run_id`.

## Rejected rows

Rows that fail to parse or violate a constraint are **quarantined, not dropped
and not silently nulled**, to:

```
s3://<processed>/_rejected/takehome/orders/ingest_date=YYYY-MM-DD/
```

Each carries its original untouched values plus `reject_reason`, which lists
every reason that row failed. The run then fails if the reject rate exceeds
`--max_reject_pct` (default 5%), so a few bad rows do not kill a batch but a
broken feed cannot load quietly. Rejects are always written before that check, so
a failed run still leaves the evidence behind.

Structural problems — a missing column, an unreadable path, an empty partition —
fail the run immediately instead, because they mean the file is not what we think
it is.

On the current file: **19 rows in, 19 accepted, 0 rejected.** Every defect above
is repaired by a cleaning rule rather than being a reason to reject.

## Open questions

- Is month-first correct for the `MM/dd/yyyy` values? (See the ambiguity note.)
- Is the `net_amount_usd` definition right?
- Should `region` have a closed allowed-list, as `channel` and `order_status` do?
  Doing so would reject an unexpected region instead of loading it.
- Which column should the processed zone partition on if queries filter on order
  date rather than arrival date? See D-12.
