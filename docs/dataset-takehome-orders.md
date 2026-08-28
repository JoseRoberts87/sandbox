# Dataset: `takehome/orders`

Order lines from the take-home dataset. The schema and every cleaning rule are
declared in `DATASET_SPECS["takehome/orders"]` in
[`glue/jobs/raw_to_processed.py`](../glue/jobs/raw_to_processed.py) — this
document explains the *why*; the job is the source of truth for the *what*.

**Source file:** `data/dpe_interview_takehome_data.csv` — CSV with a header row.
The file is replaced from time to time and its size varies, so nothing here
depends on a row count; the properties below are what hold.

## Landing it

```bash
scripts/land_sample_data.sh
```

which is equivalent to:

```bash
RAW=$(terraform -chdir=envs/dev output -raw raw_bucket_name)

aws s3 cp data/dpe_interview_takehome_data.csv \
  "s3://$RAW/takehome/orders/dpe_interview_takehome_data.csv"
```

Raw is flat — no date in the path. The `takehome/orders` prefix must match
`etl_source_name` and `etl_dataset` in `envs/dev/terraform.tfvars`, since the job
builds its input path from those. The run writes its output to the `ingest_date`
partition for the day it runs.

## Schema

| Column | Source | Stored as | Cleaning | Constraints |
|---|---|---|---|---|
| `order_id` | string | `string` | text | required, primary key, `^ord-\d+$` |
| `order_ts` | string, 4 formats | `bigint` — Unix epoch, seconds, UTC | trim | required, not in the future |
| `customer_id` | string | `string` | text | `^cust-\d+$`, **nullable** |
| `region` | string | `string` | text | one of apac, emea, latam, namer |
| `channel` | string | `string` | text | one of online, partner, retail, wholesale |
| `product_sku` | string | `string` | text | required, `^sku-\d+$`, **opaque** |
| `product_name` | string | `string` | text | — |
| `category` | string | `string` | text | one of accessories, board games, digital, miniatures, puzzles, trading cards |
| `quantity` | string | `int` | trim | >= 1; **missing → NULL** |
| `unit_price_usd` | string, may carry `$` | `double` | money | >= 0; **missing → NaN** |
| `discount_pct` | string | `double` | trim | 0 – 1; **missing → NaN** |
| `order_status` | string | `string` | text | one of cancelled, completed, pending, refunded |
| `shipping_days` | string | `int` | trim | >= 0; **missing → NULL** |

Cleaning rules:

| Rule | Applied to | Effect |
|---|---|---|
| `text` | every string column | trim, collapse internal whitespace, **lowercase** |
| `money` | `unit_price_usd` | trim, then strip currency symbols and thousands separators |
| `trim` | numerics and `order_ts` | trim only — these are cast, not cased |

Every rule trims. All text is lowercased, identifiers included: case carries no
meaning in this feed, and one convention removes a class of bug where `EMEA` and
`emea` are two different values.

### Two type choices worth knowing

**`order_ts` is an epoch.** The source carries four formats; storing seconds
since 1970 UTC removes the question of which one a row arrived in. A value with
no time component lands at midnight UTC of that date. Read it back with
`TIMESTAMP 'epoch' + order_ts * INTERVAL '1 second'`, or use the derived
`order_date` / `order_year` / `order_month` / `order_dow`.

**Money is `double`, not `decimal`.** A missing price is required to be NaN and
decimal types cannot hold one, so exactness on monetary sums is traded for that.
NaN also propagates through arithmetic, which is why the derived amounts guard
`discount_pct` with `nanvl` — otherwise one absent discount would turn every
amount on that row into NaN.

## What was wrong with the source data

Profiled before writing the spec. Every item below is real, and is why the job
declares types rather than inferring them:

| Problem | Detail |
|---|---|
| **Four timestamp formats in one column** | `yyyy-MM-dd HH:mm:ss`, `MM/dd/yyyy`, `dd-MMM-yyyy`, `yyyy-MM-dd'T'HH:mm:ss'Z'` — the first is the most common, all four are well represented |
| **Currency symbol in a numeric column** | `$159.28` in `unit_price_usd`; every other value is bare |
| **Case variants** | `region` 7 distinct → 4 real values (`North America`, `NORTH AMERICA`, `emea`, `EMEA`…); `channel` 6 → 4 |
| **Leading/trailing whitespace** | `category` 10 distinct → 6 real values (`  Puzzles `, `  Accessories `…) |
| **Blank numeric** | one blank `shipping_days` |
| **`product_sku` carries no product identity** | Effectively every SKU maps to many different product names *and* categories. This is not a few bad rows — the column does not identify a product, so it is useless as a join key or a feature |

**`order_id` is not unique.** A minority of ids appear more than once; the job
keeps the most recent by `order_ts` and quarantines the rest rather than merging
them, because which row is correct is a source-system question.

**Slash-format dates are ambiguous, and this is unresolved.** A meaningful share
of them have both components ≤ 12 — `04/03/2025` reads as 3 April or 4 March
depending on the convention. The evidence favours month-first (the first
component is never greater than 12 anywhere in the file, across a large sample),
but that is inference, not confirmation: a dd/MM source would produce exactly the
same pattern. Until the source confirms it, those rows carry a silently wrong
date, and `order_date` and the derived `order_dow` inherit it. Tracked as
**T-2.16**.

The SKU problem is a cross-row one that a row-level transform cannot fix. The job
currently logs a warning per conflicting SKU, which at this scale means a warning
for nearly every SKU on every run — noise rather than signal. Either the check
should be dropped or the column should be treated as opaque.

## Derived columns

| Column | Definition |
|---|---|
| `order_date` | `to_date(order_ts)` |
| `order_year`, `order_month`, `order_dow` | Extracted from `order_ts`, so analytics and the model share one definition |
| `gross_amount_usd` | `quantity * unit_price_usd` |
| `net_amount_usd` | `quantity * unit_price_usd * (1 - discount_pct)`, rounded |
| `discount_amount_usd` | `quantity * unit_price_usd * discount_pct`, rounded |
| `is_discounted` | `discount_pct > 0` |
| `is_digital` | `category = 'digital'` |
| `is_anonymous_customer` | `customer_id IS NULL` |
| `customer_order_seq` | Nth order for this customer by `order_ts`. Only meaningful within one snapshot — the history is whatever the current file holds — and NULL for anonymous orders |

**Assumption:** `discount_pct` is a fraction applied to the whole line, not per
unit and not already reflected in `unit_price_usd`. Unconfirmed.

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

Most defects above are repaired by a cleaning rule rather than being a reason to
reject. What is rejected, and roughly in this order of frequency:

| Reason | Nature |
|---|---|
| `quantity` below 1 | Negative quantities appear across every order status in similar proportion. Concentrated in `refunded` they would read as returns; spread evenly they read as corruption |
| duplicate `order_id` | Superseded rows, kept out rather than merged |
| `customer_id` missing | A required field, so the whole row is quarantined |

Together these have run close to the 5% `--max_reject_pct` ceiling, so the
threshold and the `quantity` rule both deserve a deliberate decision rather than
being left where they are.

## Proposed changes

Candidates from profiling the source, awaiting review:
[proposed-transformations.md](./proposed-transformations.md) (`TR-##`).

## Open questions

- Is month-first correct for the `MM/dd/yyyy` values? (See the ambiguity note.)
- Is the `net_amount_usd` definition right?
- Should `region` have a closed allowed-list, as `channel` and `order_status` do?
  Doing so would reject an unexpected region instead of loading it.
- Which column should the processed zone partition on if queries filter on order
  date rather than arrival date? See D-12.
