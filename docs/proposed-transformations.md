# Proposed transformations

> **TR-01 – TR-15 were approved and implemented on 2026-08-27**, together with
> seven further changes from review: epoch timestamps, trimming everywhere,
> NULL defaults for missing integers, NaN defaults for missing floats,
> rejection of exact duplicate rows, lowercasing all text, and `$` stripping.
> **TR-08 and TR-16 remain open** — both need an answer from whoever owns the
> feed, not a decision from us.

Candidate changes to the `takehome/orders` transform, from profiling the source
file. Each item carries its reasoning and a **Decision** line; append new ones
at the bottom.

Implemented behaviour lives in `DATASET_SPECS` in
[`glue/jobs/raw_to_processed.py`](../glue/jobs/raw_to_processed.py) and is
described in [dataset-takehome-orders.md](./dataset-takehome-orders.md). This
file is the queue in front of it.

Nothing below depends on the size of the file — the source is replaced from time
to time, so these are stated as properties, not counts.

| APPROVED | ID | Transformation | Kind | Decision |
|---|---|---|---|---|
|[x]| TR-01 | Normalise `region` form, not just case | conformance | done |
|[x]| TR-02 | Allowed-list for `region` | validation | done |
|[x]| TR-03 | Treat `product_sku` as opaque; drop the SKU consistency check | conformance | done |
|[x]| TR-04 | Decide the `quantity < 1` rule | validation | done |
|[x]| TR-05 | Demote `customer_id` from required | validation | done |
|[x]| TR-06 | Format constraints on the ID columns | validation | done |
|[x]| TR-07 | Reject future-dated orders | validation | done |
|[x]| TR-08 | Cross-field rule: digital products with shipping days | validation | **deferred — needs TR-15 confirmed** |
|[x]| TR-09 | Re-derive `--max_reject_pct` | policy | done |
|[x]| TR-10 | `discount_amount_usd` | derived | done |
|[x]| TR-11 | `is_discounted` | derived | done |
|[x]| TR-12 | `is_digital` | derived | done |
|[x]| TR-13 | `order_year`, `order_month`, `order_dow` in processed | derived | done |
|[x]| TR-14 | `customer_order_seq` | derived | done |
|[x]| TR-15 | Reconsider `shipping_days` as a model feature | model | done |
|[x]| TR-16 | Confirm the slash-date convention with the source | model / correctness | **open — needs the source** |

---

## Conformance

### TR-01 — Normalise `region` form, not just case
**Column:** `region`
**Now:** `code` cleaning — trimmed, whitespace collapsed, uppercased.
**Problem:** The values are inconsistent in *form*, not only case: some are
acronyms, at least one is spelled out in full. Cleaning fixes the case and
leaves the inconsistency.
**Proposal:** Pick one convention — acronyms throughout, or full names
throughout — and map to it. Pairs naturally with TR-02.
**Decision:** approved 2026-08-27 — implemented

### TR-03 — Treat `product_sku` as opaque; drop the SKU consistency check
**Column:** `product_sku`
**Now:** A `consistency` check logs a warning when one SKU maps to more than one
`(product_name, category)`.
**Problem:** Effectively every SKU maps to many product names *and* categories.
This is not a handful of bad rows — the column does not identify a product. The
check therefore warns for nearly every SKU on every run, which is noise, and any
consumer treating the SKU as a product key will be wrong.
**Proposal:** Drop the check, and document the column as an opaque identifier —
not a join key, not a feature. If a real product dimension appears later,
revisit.
**Decision:** approved 2026-08-27 — implemented

---

## Validation

### TR-02 — Allowed-list for `region`
**Column:** `region`
**Now:** No `allowed` constraint. `channel` and `order_status` both have one.
**Problem:** An unexpected region loads silently, where an unexpected channel is
quarantined. The asymmetry is accidental rather than reasoned.
**Proposal:** Add an allowed-list once TR-01 settles the canonical form.
**Decision:** approved 2026-08-27 — implemented

### TR-04 — Decide the `quantity < 1` rule
**Column:** `quantity`
**Now:** `min: 1`, so anything below is quarantined. This is the single largest
source of rejects.
**Problem:** Negative quantities appear across every order status in roughly
similar proportion. Concentrated in `refunded` they would read as return lines
and deserve to be kept with a sign convention; spread evenly across statuses
they read as injected corruption and deserve rejecting. The even spread favours
rejection — but it is worth confirming rather than inferring, because the rule
is discarding a non-trivial share of the feed.
**Proposal:** Confirm with the source. If corruption, keep `min: 1` and close the
question. If returns, admit them and add an `is_return` flag, excluding them from
revenue aggregates.
**Decision:** approved 2026-08-27 — implemented

### TR-05 — Demote `customer_id` from required
**Column:** `customer_id`
**Now:** `required: true`, so a blank quarantines the entire row.
**Problem:** An order with an unknown customer is still a real order with real
revenue. Discarding it loses the sale to keep the dimension clean.
**Proposal:** Make it nullable, add an `is_anonymous_customer` flag, and let
customer-level analysis filter on it. Note this weakens TR-14, which needs a
customer to sequence by.
**Decision:** approved 2026-08-27 — implemented

### TR-06 — Format constraints on the ID columns
**Columns:** `order_id`, `customer_id`, `product_sku`
**Now:** Cleaned as `code`, no pattern check.
**Problem:** None observed — every value matches its expected shape. This is
insurance, not a fix.
**Proposal:** Add a regex constraint per column so a malformed feed is
quarantined rather than loaded. Cheap, and the failure it prevents is silent.
**Decision:** approved 2026-08-27 — implemented

### TR-07 — Reject future-dated orders
**Column:** `order_ts`
**Now:** Any parseable timestamp is accepted.
**Problem:** None observed, but nothing prevents one, and a future order date
would quietly corrupt every time-based aggregate and land in the wrong
`order_date`.
**Proposal:** Quarantine rows where `order_ts` is beyond the run date, with a
small tolerance for clock skew.
**Decision:** approved 2026-08-27 — implemented

### TR-08 — Cross-field rule: digital products with shipping days
**Columns:** `category` + `shipping_days`
**Now:** No relationship enforced.
**Problem:** Digital products carry shipping days almost universally. Either the
column does not mean what its name suggests, or the category is wrong, or the
value is noise. All three are worth knowing.
**Proposal:** Decide what the field means first (see TR-15), then either add a
warning-level check or leave it alone deliberately. Do not add a rejecting rule
before the meaning is settled.
**Decision:** approved 2026-08-27 — **deliberately not implemented.** Adding a
rule before the column's meaning is settled would encode a guess. Waits on
TR-15 being confirmed with the source.

### TR-09 — Re-derive `--max_reject_pct`
**Where:** job argument, currently 5%.
**Problem:** The combined reject rate has run close to the ceiling. Passing by a
narrow margin is luck, not a threshold — a small drift in the feed fails an
otherwise good batch, and the number was chosen before any real data existed.
**Proposal:** Set it from observed behaviour once TR-04 and TR-05 are settled,
since both change the rate materially. Consider splitting it: a low ceiling for
structural rejects and a higher one for known-noisy fields.
**Decision:** proposal approved

---

## Derived columns

### TR-10 — `discount_amount_usd`
**Definition:** `gross_amount_usd - net_amount_usd`
**Why:** The money actually given away. Currently every consumer recomputes it,
and each one re-derives the same assumption about how discounts apply.
**Decision:** approved 2026-08-27 — implemented

### TR-11 — `is_discounted`
**Definition:** `discount_pct > 0`
**Why:** Discounts are sparse and take few distinct values, so the boolean is
more useful than the rate for both filtering and modelling.
**Decision:** approved 2026-08-27 — implemented

### TR-12 — `is_digital`
**Definition:** `category = 'digital'`
**Why:** Digital and physical orders behave differently — shipping, returns,
fulfilment. A flag is cheaper than string-matching the category everywhere, and
it is the natural partner to TR-08.
**Decision:** approved 2026-08-27 — implemented

### TR-13 — `order_year`, `order_month`, `order_dow` in the processed table
**Definition:** Extracted from `order_ts`.
**Why:** `order_dow` already exists but only inside the ML training view, so
analytics consumers cannot use it without recomputing. Moving the extraction
into the processed table gives one definition for everyone.
**Note:** All three inherit any error from TR-16.
**Decision:** approved 2026-08-27 — implemented

### TR-14 — `customer_order_seq`
**Definition:** Row number per `customer_id`, ordered by `order_ts`.
**Why:** Whether an order is a customer's first or fifteenth is one of the more
predictive things available, and it needs no data we do not already hold.
**Caveats:** It is a window function over the whole dataset, so it costs a
shuffle. It is also only correct within one snapshot — a customer's history is
whatever the current file contains. And TR-05 would leave anonymous orders
unsequenced.
**Decision:** approved 2026-08-27 — implemented

---

## Model

### TR-15 — Reconsider `shipping_days` as a feature
**Now:** Excluded from `ml.orders_training` as leakage, on the grounds that it is
"known only after shipping".
**Problem:** That reasoning looks wrong. The column is populated almost
universally on `pending` orders — which have not shipped — and on `cancelled`
orders, which never will. It is therefore an *estimate or promise made at order
time*, not an observed outcome, and excluding it discards a legitimate and
probably useful feature.
**Proposal:** Confirm the meaning with the source. If it is an estimate, add it
to the training view and to `FEATURES` in `ml/train.py` (both, or the drift test
fails). If it is an actual, the current exclusion is correct and should stay.
**Decision:** approved 2026-08-27 — implemented

### TR-16 — Confirm the slash-date convention with the source
**Column:** `order_ts`
**Now:** Slash dates are parsed `MM/dd/yyyy`.
**Problem:** A meaningful share of them have both components ≤ 12 and cannot be
disambiguated from the data. The evidence favours month-first — the first
component is never greater than 12 anywhere in the file — but a dd/MM source
would produce exactly that pattern, so this is inference, not confirmation. If
it is wrong, those rows carry a silently incorrect date and `order_date`,
`order_dow` and every time-based aggregate inherit the error.
**Proposal:** Ask whoever owns the feed. **This one cannot be resolved by
looking harder at the data.** If they cannot say, consider quarantining
ambiguous slash dates rather than guessing.
**Related:** T-2.16.
**Decision:** approved 2026-08-27 — **still open.** Parsing is unchanged
(month-first); this needs an answer from the source, not from us.

---

## Added by review

_Append here._

### TR-17 —
**Column:**
**Why:**
**Proposal:**
**Decision:**
