# Protect reserved GL account numbers from automatic account allocation

**Status:** Open — follow-up task, not part of ADR-025 / SAD
**Raised:** 2026-09-16, during SAD AccountingMapping setup
**Severity:** 🟡 Medium — latent; no data is wrong today
**Related:** ADR-025 (Supplier Settlement Adjustment)

> This document records a finding. It proposes no fix and changes no code.
> `backend/accounting/wages.py` and `backend/routes/invoices.py` were read only.

---

## The finding

Finance approved four GL account numbers for Supplier Settlement Adjustments:

| Number | Account | Side |
|---|---|---|
| `5250` | مصروف فروقات تسوية الموردين | financial (SAR) |
| `75250` | مصروف فروقات تسوية الموردين – وزني | weight (memo) |
| `4120` | إيراد فروقات تسوية الموردين | financial (SAR) |
| `74120` | إيراد فروقات تسوية الموردين – وزني | weight (memo) |

Two of them — **`4120`** and **`5250`** — already appear as claimable candidates
inside two unrelated auto-creating helpers:

| Location | Candidate list | Creates |
|---|---|---|
| [`accounting/wages.py:49`](../../backend/accounting/wages.py#L49) | `('4110','4111','4112','4113','4120')` | «إيرادات عمولة السداد بذهب صافي» |
| [`routes/invoices.py:3114`](../../backend/routes/invoices.py#L3114) | `('5240','5241','5242','5250')` | «رسوم السداد بعيار أقل» |

Both helpers take **the first number in the list that is not yet used** and
create an account on it. Neither knows that `4120`/`5250` now carry a different,
finance-assigned meaning.

Callers: `posting_routes.py:3364` and `posting_routes.py:3392`, both inside the
karat-difference posting path.

### Why it has not broken anything yet

In the environment inspected, all nine numbers (`4110`–`4113`, `4120`,
`5240`–`5242`, `5250`) are free, so each helper would still claim its first
choice (`4110`, `5240`). The collision only becomes reachable as the chart fills
up and the earlier candidates get taken.

### What breaks when it does

Two orderings, two different failures:

- **Helpers run first** → `4120`/`5250` are occupied by «عمولة السداد» /
  «رسوم السداد بعيار أقل». SAD's `AccountingMapping` would then point at an
  account whose name and purpose are something else entirely. Settlement
  differences would land in the wrong ledger line, silently.
- **SAD accounts created first** → the helpers skip every candidate, fall
  through to their unconditional tail (`chosen_number = '4110'` / `'5240'`) and
  attempt to create an account on a number that is already taken. That path
  performs **no uniqueness check**, so it relies on the DB constraint and
  surfaces as an `IntegrityError` mid-posting.

---

## Audit of the allocation mechanism

Read-only findings, answering the questions that scoped this task.

**Is there a central account-number allocator?**
Yes — `account_number_generator.get_next_account_number(parent, use_spacing)`,
backed by `_first_unused_number_in_range()`. It derives a numeric range from the
parent account, reads the numbers already used in that range, and returns the
first gap. Used by `party_account_service`, `employee_account_helpers`, and
`employee_cash_safe_helpers`.

**Are the two conflicting lists part of that convention?**
No. `wages.py` and `invoices.py` do not call the allocator at all; each carries
its own hardcoded tuple. They are exceptions to the established mechanism, which
is why the reservation problem shows up there and not in the party/employee
paths.

**Is there a central list of reserved numbers?**
No. Nothing in the codebase marks a number as reserved. The allocator's only
notion of "taken" is "a row already exists with this `account_number`" — a
number that is *approved but not yet created* is indistinguishable from a free
one. That is precisely the gap this task exists to close.

**Does `chosen_number` verify uniqueness before creating?**
Partly. The loop tests each candidate with
`Account.query.filter_by(account_number=candidate).first()`. But the fallback
that runs when every candidate is taken assigns `'4110'` / `'5240'`
unconditionally, with no check — the one path that is guaranteed to collide is
the one that skips the check.

**Is there race/concurrency protection?**
No. Both the central allocator and the two local helpers are check-then-act with
no row lock, advisory lock, or retry. Two concurrent requests can select the
same number. The only backstop is `Account.account_number` being
`unique=True` (`models.py:92`), which converts the race into an `IntegrityError`
rather than a duplicate row — a crash, not corruption.

**Are there tests covering account-number collision?**
For these two helpers, none — no test references
`_ensure_gold24k_commission_revenue_account` or
`_ensure_karat_diff_expense_account`. The only adjacent coverage is
`test_chart_of_accounts_security.py::test_duplicate_account_number_returns_409`,
which asserts the HTTP API rejects a duplicate; it does not exercise either
allocator, the fallback branch, or concurrent allocation.

---

## What this task should decide

Not prescribing an implementation — these are the open questions:

1. Where should reserved numbers live so that both the central allocator and any
   local helper must consult them? (A registry module, a DB flag on a
   placeholder account row, or a config table are all plausible; the project's
   "Policy is Data, Law is Code" rule applies.)
2. Should `wages.py` and `invoices.py` be migrated onto
   `get_next_account_number()` rather than keeping private candidate lists?
3. Should the unconditional fallback (`'4110'` / `'5240'`) be replaced by a loud
   failure? Creating an account on a number known to be taken cannot succeed.
4. Does allocation need a lock, or is the unique constraint plus a retry
   acceptable given how rarely accounts are created?

**Constraint carried over from ADR-025:** the finance-approved numbers
`4120 · 5250 · 74120 · 75250` do not change. The collision is a defect in the
allocation mechanism, not a reason to renumber approved accounts.
