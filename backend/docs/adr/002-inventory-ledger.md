# ADR-002: Append-Only Event Log (InventoryLedger)

**Status:** Accepted  
**Date:** 2026-07-05  
**Deciders:** Architecture review

---

## Context

Gold inventory systems require a complete, auditable history of every weight movement. A mutable balance table (update-in-place) loses this history and makes it impossible to answer questions like "what was the inventory level at 14:32 on date X?" or "which document caused this discrepancy?"

## Decision

`InventoryLedger` is an **append-only event log**. Each row represents one inventory movement from one source line:

```
id | source_type | source_id | source_line_id | movement_type
   | branch_id  | category_id | karat | weight_delta
   | posted_at  | posted_by  | notes
```

**Rules:**
1. Rows are never updated or deleted — only inserted.
2. `weight_delta` is signed: positive = stock IN, negative = stock OUT.
3. Reversals are new rows with `movement_type = '<original>_reversal'` and `weight_delta = -original`, not modifications.
4. Current balance for a bucket = `SUM(weight_delta)` filtered by `(branch_id, category_id, karat)`.

**Idempotency** is enforced at two levels:
- Service level: check for existing row before inserting.
- Database level: `UNIQUE(source_type, source_id, source_line_id, movement_type)` constraint.

## Consequences

**Positive:**
- Complete audit trail — every gram movement is traceable to its source document and line.
- `BalanceInvariantChecker` can recompute the ground truth at any time from the Ledger alone.
- Snapshot isolation: count sessions can freeze a `snapshot_ledger_id` and compute expected balance at that exact point in history.
- Debugging: any balance discrepancy can be traced by replaying Ledger rows.

**Negative / Trade-offs:**
- The Ledger grows indefinitely. Archival strategy will be needed after ~5 years of operation (low priority; gold ERP data volumes are modest).
- Balance queries require `SUM()` over potentially many rows if not using the Balance projection. This is why `InventoryBalance` exists as a cache (see ADR-003).

## Alternatives considered

- **Mutable balance table only**: Update a single row per bucket on every transaction. Rejected: no history, impossible to audit, hard to debug drift.
- **Soft-delete / update-with-version**: Mark rows as cancelled instead of appending reversals. Rejected: complicates queries and breaks `SUM()` semantics.

## Addendum — 2026-10-01: posting cycles (UNPOST-001 U1, ADR-034)

The log allowed one row per `(source_type, source_id, source_line_id, movement_type)`:
one posting and one reversal per line, ever. A document posted, unposted and posted
again could not be written back — the re-post hit `uq_inventory_ledger_idempotency`,
and before that the idempotency check skipped it because an original row existed —
so the round trip ADR-034 requires left the document out of inventory. And
`movement_type` was `varchar(30)`: `purchase_from_customer_reversal` is 31, so a
customer purchase could never be reversed. Neither had happened in production
(1,301 rows on the 30 Sep 2026 copy, no reversal at all): nothing called `reverse()`.

- `cycle` (integer, default 0) joins the unique key. A line's first posting is cycle 0;
  a re-post after a reversal is the next cycle; a reversal carries the cycle of the
  posting it reverses. Rules 1–3 above stand: no row is updated or deleted.
- Whether a line is posted is its **net** — its originals plus their reversals — not
  whether an original row exists. `post()` writes when the net is zero; `reverse()`
  reverses what stands, for item lines (`invoice`) and a supplier purchase's karat
  lines (`invoice_karat`) alike (it used to see item lines only).
- `movement_type` is `varchar(40)`.

Migration `20261001_inventory_ledger_cycle` (additive: existing rows are cycle 0 and
satisfy the new key). Proof: `backend/tests/test_inventory_ledger_posting_cycles.py`.
