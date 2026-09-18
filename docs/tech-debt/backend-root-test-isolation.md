# Root-level backend tests share one un-reset database across a full session

**Status:** Open — independent of any feature work; not caused by, and not fixed by, the bonus-scheduler correction it was found alongside
**Raised:** 2026-09-19, while verifying the bonus-scheduler fix caused no regression
**Severity:** 🟡 Medium — the tests affected are not currently trusted signals when run together; nothing in production is wrong
**Related:** the `goal_period_filter` fix in `backend/bonus_calculator.py` / `backend/bonus_scheduler.py`

> This document records a finding. It proposes no fix and changes no code.
> No test file was modified while investigating this.

---

## The finding

`backend/tests/` (the directory this and prior sessions have used as "the
backend suite," 285 tests) is clean and passes in isolation. But `backend/`
also holds **72 root-level `test_*.py` files**, predating the `tests/`
convention, that nothing in this project has run together in one `pytest`
invocation before now. Doing so — `pytest .` from `backend/` — produces:

```
59 failed, 481 passed, 19 skipped, 14 errors
```

Proven independent of the bonus-scheduler work: the same command produces the
identical `59 failed / 14 errors` both with and without that fix applied
(verified via `git stash` on `bonus_calculator.py` / `bonus_scheduler.py`
alone). This is pre-existing.

## Root mechanism

```python
# backend/conftest.py
@pytest.fixture(scope='session', autouse=True)
def initialize_db():
    reset_database()   # runs once, at the start of the whole pytest session
```

There is no per-test transaction rollback anywhere in `conftest.py`. Every test
in every one of the 72 files commits into the **same** SQLite file for the rest
of the session. Individual files clean up their own rows inconsistently (some
do, in fixture teardowns; most do not). This is invisible running any one file
alone — which is how all 72 were presumably authored and verified — and only
surfaces when the full set accumulates state together.

## Two distinct causes were traced with evidence, not assumed to be one

**A. A unique-constraint convention that two files did not follow.**
`Invoice` carries `UniqueConstraint('invoice_type', 'invoice_type_id')`. Six
inventory test files coordinate non-overlapping ID ranges specifically to
avoid colliding with each other when run together:

```
test_inventory_posting_service.py : itertools.count(200_000)
test_inventory_balance.py         : itertools.count(300_000)
test_inventory_phase3.py          : itertools.count(400_000)
test_inventory_phase4.py          : itertools.count(500_000)
test_inventory_phase5.py          : itertools.count(600_000)
test_inventory_api.py             : itertools.count(900_000)
```

`test_bonus_phase2_reversal.py` and `test_bonus_phase6_estimate.py` instead
hardcode `invoice_type_id=1`. Colliding with an earlier file's committed row
raises `IntegrityError: UNIQUE constraint failed: invoice.invoice_type,
invoice.invoice_type_id` at fixture setup — accounting for 9 of the 14 errors.

**B. A table that goes missing mid-session.**

```
sqlite3.OperationalError: no such table: users
```

appears 10 times across unrelated files (`test_supplier_purchase_return_invoice.py`,
`test_suppliers_list_live_balances.py`, others). This is schema loss, not a data
collision — something earlier in collection order tears down or repoints the
schema without fully restoring it. **Not traced to a specific file**: doing so
needs bisection (running collection-ordered halves of the 72 files against each
other) that was out of scope for verifying the bonus fix.

The remaining ~50 failures were sampled but not individually traced; the
diversity of affected subsystems (bonus, inventory, clearing settlement, safe
box, points) is consistent with accumulated cross-file state rather than 50
unrelated defects, but this is not proven file-by-file.

## A separate, smaller, unrelated finding

`test_bonus_points_parity.py::TestSettingsPropagation::test_race_and_bonus_read_same_config`
fails standalone, alone, with no other files involved — not part of the
isolation problem above. Its own body calls `get_race_points_config()` outside
an `app.app_context()`, so the call silently falls back to a default
(`gold_weight`) instead of reading the configured value (`profit_cash`):

```
[get_race_points_config] ERROR reading settings: Working outside of application context.
```

A one-line test bug, unrelated to bonus scheduling or to the isolation
mechanism above.

---

## Open questions for whoever picks this up

1. Should the 72 root-level files be given per-test rollback (the standard
   fix — wrap each test in a SAVEPOINT and roll back in teardown), or migrated
   into `tests/` where that discipline already exists?
2. Is running the full root-level set in one process even an intended
   CI shape, or was `pytest tests/` always meant to be the real gate and the
   root-level files are meant to run individually / are legacy?
3. Which file drops the `users` table? Needs bisection, not inspection.
4. `test_bonus_phase2_reversal.py` / `test_bonus_phase6_estimate.py` could
   trivially join the existing `_id_seq` offset convention — the smallest
   possible fix, but only closes 9 of 73 findings and doesn't address the
   underlying no-rollback design.
