# Runbook — Deploying Supplier Settlement Adjustments (SAD)

**Applies to:** ADR-025 · `backend/services/supplier_settlement_adjustment_service.py`
**First executed:** 2026-09-19 on production (`yasargold-db`) — every command below is transcribed from that run
**Audience:** whoever deploys SAD to an environment that has never run it

---

## What SAD needs before it can post anything

Three things, and they arrive by three different routes. Missing any one of them
leaves the feature *looking* installed while every settlement is refused.

| # | Requirement | Where it comes from |
|---|---|---|
| 1 | `supplier_settlement_policy` + `supplier_settlement_adjustment` tables | migration `20260916`, **or** `db.create_all()` at boot |
| 2 | One `SupplierSettlementPolicy` row in effect | migration `20260916` seed — **only** the migration |
| 3 | Four `AccountingMapping` rows for `تسوية_مورد` | manual, per environment (GL numbers are a finance decision) |

### The trap that caught production

`db.create_all()` runs at application boot and creates the two tables from
`models.py`. The seed lives in the migration. So an environment that boots the
app before running `alembic upgrade` ends up with the tables present and empty,
SAD appearing installed, and every attempt refused with:

```
المورد غير مؤهل للتسوية: policy_configured: لا توجد SupplierSettlementPolicy نافذة في هذا التاريخ.
```

That message means **the table exists and is empty** — not that it is missing.
Read it as "the migration has not run here yet".

---

## 1. Read the current state (read-only)

Substitute the container, user and database from your own environment. On
production these were `yasargold-db`, user `yasargold`, database `yasargold_db`
— note the user and database names differ, and neither is the `postgres`
default.

```powershell
docker exec yasargold-db printenv POSTGRES_USER POSTGRES_DB
```

```powershell
docker exec yasargold-db psql -U yasargold -d yasargold_db -tAc "SELECT 'alembic=' || version_num FROM alembic_version UNION ALL SELECT 'policy_rows=' || count(*) FROM supplier_settlement_policy UNION ALL SELECT 'sad_mappings=' || count(*) FROM accounting_mapping WHERE account_type LIKE 'supplier%settlement%' UNION ALL SELECT 'acct ' || account_number || ' tw=' || tracks_weight::text || ' memo=' || coalesce(memo_account_id::text,'none') FROM account WHERE account_number IN ('5250','4120','75250','74120');"
```

**PowerShell notes**, each learned by failing first:

- No `sh -c`. Nested quotes get mangled and the command returns empty with no
  error at all.
- No Arabic literals in SQL. `account_type LIKE 'supplier%settlement%'` reaches
  the same rows as `operation_type = 'تسوية_مورد'` without risking the encoding.
  To confirm the operation type is exactly right, compare its lengths instead:
  `char_length` = 10 and `octet_length` = 19.
- `printenv VAR`, never `echo $VAR` — PowerShell expands `$VAR` on your own
  machine before the container ever sees it.
- `<placeholder>` is not a placeholder to PowerShell. `<` and `>` are
  redirection operators and the command fails on them.

Expected on a fresh environment:

```
alembic=20260908_fix_legacy_transaction_type_both
policy_rows=0
sad_mappings=4
acct 5250 tw=false memo=1250
acct 75250 tw=true memo=1249
acct 4120 tw=false memo=1252
acct 74120 tw=true memo=1251
```

`memo=` carries account **ids**, not account numbers. Step 2 resolves them.

---

## 2. Verify the mappings before migrating

Four rows existing is not the same as four rows resolving. A weight mapping
pointing at an account that cannot carry grams is refused at posting time, which
is a worse moment to find out.

```powershell
docker exec yasargold-db psql -U yasargold -d yasargold_db -tAc "SELECT m.account_type || ' -> ' || a.account_number || ' (tw=' || a.tracks_weight::text || ', memo=' || coalesce(mm.account_number,'none') || ' tw=' || coalesce(mm.tracks_weight::text,'-') || ', active=' || m.is_active::text || ', op=' || char_length(m.operation_type)::text || '/' || octet_length(m.operation_type)::text || ')' FROM accounting_mapping m JOIN account a ON a.id = m.account_id LEFT JOIN account mm ON mm.id = a.memo_account_id WHERE m.account_type LIKE 'supplier%settlement%' ORDER BY 1;"
```

Production returned, and this is the shape to aim for:

```
supplier_settlement_expense         -> 5250 (tw=false, memo=75250 tw=true, active=true, op=10/19)
supplier_settlement_income          -> 4120 (tw=false, memo=74120 tw=true, active=true, op=10/19)
supplier_weight_settlement_expense  -> 5250 (tw=false, memo=75250 tw=true, active=true, op=10/19)
supplier_weight_settlement_income   -> 4120 (tw=false, memo=74120 tw=true, active=true, op=10/19)
```

What each column must show:

- **The weight mappings point at the financial account, not the memo one.**
  `_resolve_account_id_for_amount_type()` redirects the gold line to the paired
  memo account on its own. Mapping straight to `75250` bypasses the pairing the
  rest of the ledger relies on.
- `memo=… tw=true` — the paired account tracks weight. Without it,
  `_resolve_weight_settlement_account_id()` refuses.
- `active=true`, and `op=10/19` on every row.

If the four mappings are absent, create them with the GL numbers **finance has
approved for that environment**. Never invent an account number, and never let
SAD fall back to a default account: the service raises
`MissingAccountingMappingError` by design instead.

---

## 3. Run the migration

`alembic.ini` lives at `/app/backend`, while the image's `WORKDIR` is `/app` —
so the working directory has to be given explicitly or alembic reports
"No config file 'alembic.ini' found".

```powershell
docker exec -w /app/backend yasargold-backend alembic upgrade head
```

If the `alembic` entry point is not on PATH in the image:

```powershell
docker exec -w /app/backend yasargold-backend python -m alembic current
docker exec -w /app/backend yasargold-backend python -m alembic upgrade head
```

Production output — one migration, and the seed reported explicitly:

```
INFO  [alembic.runtime.migration] Running upgrade 20260908_fix_legacy_transaction_type_both -> 20260916_supplier_settlement_adjustment
[SAD migration] PRE-CHECK — policy table: exists (0 rows) · adjustment table: exists
[SAD migration] REPORT — tables: policy pre-existing, adjustment pre-existing · policy rows 0 → 1 (seeded initial policy)
```

"policy pre-existing" is normal and is the `create_all()` effect described
above. The seed is keyed on the policy table being **empty**, not on the
migration having created it, so it still runs.

**No container restart is needed.** The policy is read live at every decision
(`_resolve_policy` → `SupplierSettlementPolicy.in_effect_at(now)`), not cached
at boot.

---

## 4. Confirm

```powershell
docker exec -w /app/backend yasargold-backend python -m alembic current
```

```powershell
docker exec yasargold-db psql -U yasargold -d yasargold_db -tAc "SELECT 'id=' || id || ' tol_cash=' || tolerance_cash || ' tol_wt=' || tolerance_weight || ' cap_cash=' || period_cap_cash || ' cap_wt=' || period_cap_weight || ' review=' || review_threshold_cash || ' from=' || effective_from || ' to=' || coalesce(effective_to::text,'open') || ' IN_EFFECT=' || (effective_from <= now() AND (effective_to IS NULL OR now() < effective_to))::text FROM supplier_settlement_policy;"
```

`IN_EFFECT=true` is the line that matters — the predicate is the same half-open
interval `in_effect_at()` applies in code.

Then open any draft in the app and press **مراجعة**. The preview endpoint is
read-only and reports what a post would decide: the main-karat equivalent, the
policy limits, the month's consumption, and the blocking reason by name. It
writes nothing, so it is safe to use as the final smoke test.

---

## After a successful deployment, expect refusals

Every gate below is SAD working correctly, not a deployment fault:

| Blocking code | Meaning |
|---|---|
| `has_residual` | the supplier's balance is already closed |
| `no_unpaid_invoices` · `no_pending_vouchers` | clean up the supplier's open documents first |
| `below_review_threshold` | the residual exceeds the review threshold (500) — this is an unexplained balance, not a settlement difference |
| `within_operation_tolerance` · `within_period_cap` | the amount or the month's allowance is exhausted |
| `accounting_configured` | step 2 was skipped or is wrong |

On the first production deployment **no supplier out of 26 qualified**. The
feature sits ready for the first justified residual; that is the expected state,
not a problem to debug.

---

## Appendix A — a database whose alembic history was never run

Symptom: `alembic upgrade head` dies with `relation "..." already exists` on a
table nobody expected it to create.

Cause: the environment's schema was built by `db.create_all()` from `models.py`,
while `alembic_version` was stamped somewhere in the middle. Reaching a
**mergepoint** revision then requires replaying an entire branch that was never
applied, and every `create_table` on it collides.

This happened on the development machine, where `20260908` is a mergepoint with
two parents and only one was stamped, leaving 79 migrations on the other branch
unapplied.

**Do not do this on production.** Production's history is genuine; if production
ever shows this symptom, stop and investigate rather than stamping.

The development fix was to stamp the missing parent — but only after proving the
stamp was honest, on two counts:

1. **The branch is already represented in the schema.** A symbolic replay of the
   79 migrations is not sufficient evidence on its own; it reported seven false
   gaps that turned out to be absent from production too. The decisive check was
   a direct schema comparison against a database that genuinely ran the
   migrations: zero tables and zero columns missing, with 12 type differences
   (`double precision` vs `real`, `json` vs `text`) all explained by
   `create_all()` using SQLAlchemy's generic types.

2. **Exactly the intended migrations will run afterwards.** Computed before
   touching anything:

   ```python
   from alembic.config import Config
   from alembic.script import ScriptDirectory
   script = ScriptDirectory.from_config(Config('alembic.ini'))
   list(script._upgrade_revs('heads', ('<parent-1>', '<parent-2>')))
   ```

   One stamped head planned 13 migrations; both parents planned 2.

The stamp itself **adds** a head, it does not replace one — a mergepoint needs
both parents present:

```sql
INSERT INTO alembic_version (version_num) VALUES ('<missing-parent>');
```

Take a `pg_dump` first. On the dev run nothing was written by the failed
attempt — PostgreSQL's DDL is transactional and it rolled back cleanly — but
that is luck to verify, not to rely on.

---

## Appendix B — known open issues

- **Policy timestamps are UTC, business decisions are local.** The migration
  seeds `effective_from` with `CURRENT_TIMESTAMP` from the database container
  (UTC), while the service reads the clock through `_now()` in Riyadh local time
  per ADR-015. Production's policy shows `2026-09-18 21:11` for a migration run
  after local midnight on 09-19. Harmless in this direction — the policy simply
  became effective earlier — but `period_key` is computed locally while policy
  timestamps are not, which could matter at a month boundary.
- **Migrations have no tests.** 82 files, zero coverage. `20260916` has now been
  rehearsed on a production copy and run on production, but the general gap
  stands.
