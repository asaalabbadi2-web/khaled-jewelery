-- verify_ledger.sql — the canonical post-restore / post-migration verification.
--
-- ONE file, TWO consumers:
--   • scripts/verify_backup.ps1  — runs it against a throwaway restore of a
--     backup archive, before that archive is trusted.
--   • docs/runbooks/disaster-recovery.md §5/§7 — runs it against the real
--     database after restore and again after `alembic upgrade head`.
-- Two copies of these checks would drift; there is only this one.
--
-- Contract: prints FACTS, then RAISES on broken INVARIANTS.
-- Run with ON_ERROR_STOP so a raised invariant fails the caller's exit code:
--   psql -v ON_ERROR_STOP=1 -f scripts/verify_ledger.sql
--
-- Read-only. Safe against production.

\set ON_ERROR_STOP on
\timing off
\pset pager off

\echo '── Schema ───────────────────────────────────────────────────────'
SELECT version_num AS alembic_version FROM alembic_version;
SELECT count(*) AS public_tables
  FROM information_schema.tables
 WHERE table_schema = 'public';

\echo '── Volume ───────────────────────────────────────────────────────'
SELECT (SELECT count(*)      FROM invoice)             AS invoices,
       (SELECT max(date)::date FROM invoice)           AS last_invoice,
       (SELECT count(*)      FROM invoice_payment)     AS payments,
       (SELECT count(*)      FROM journal_entry)       AS journal_entries,
       (SELECT count(*)      FROM journal_entry_line)  AS je_lines,
       (SELECT count(*)      FROM supplier)            AS suppliers;

\echo '── Cash ledger balance (live lines only) ────────────────────────'
-- `is_deleted = false` is load-bearing, not cosmetic: soft-deleted lines are
-- excluded from the books and do NOT balance on their own (measured
-- 2026-09-26 on the 24 Sep production backup: 116,378.00 out of balance
-- across all lines, 0.00 across live lines).  Dropping the filter turns this
-- invariant into a false alarm.
SELECT round(sum(cash_debit)::numeric, 2)                    AS total_debit,
       round(sum(cash_credit)::numeric, 2)                   AS total_credit,
       round((sum(cash_debit) - sum(cash_credit))::numeric, 2) AS difference
  FROM journal_entry_line
 WHERE is_deleted = false;

\echo '── Who can log in ───────────────────────────────────────────────'
SELECT role, count(*) AS accounts
  FROM app_user
 WHERE is_active
 GROUP BY role
 ORDER BY role;

\echo '── Invariants ───────────────────────────────────────────────────'
DO $$
DECLARE
    diff      numeric;
    invoices  bigint;
    versions  bigint;
    admins    bigint;
BEGIN
    SELECT count(*) INTO versions FROM alembic_version;
    IF versions <> 1 THEN
        RAISE EXCEPTION 'alembic_version holds % rows, expected exactly 1', versions;
    END IF;

    SELECT count(*) INTO invoices FROM invoice;
    IF invoices = 0 THEN
        RAISE EXCEPTION 'no invoices — this is not a restored production database';
    END IF;

    -- Tolerance of one halala: cash columns are double precision, so an exact
    -- `<> 0` would fail on representation noise rather than on a real break.
    SELECT round((sum(cash_debit) - sum(cash_credit))::numeric, 2)
      INTO diff
      FROM journal_entry_line
     WHERE is_deleted = false;
    IF diff IS NULL OR abs(diff) > 0.01 THEN
        RAISE EXCEPTION 'CASH LEDGER OUT OF BALANCE by % — stop, do not migrate', diff;
    END IF;

    -- A restore nobody can log into is a failed restore.
    SELECT count(*) INTO admins
      FROM app_user
     WHERE is_active AND role = 'system_admin';
    IF admins = 0 THEN
        RAISE EXCEPTION 'no active system_admin account — nobody could administer this system';
    END IF;

    RAISE NOTICE 'INVARIANTS OK — cash difference %, % invoices, % system_admin account(s)',
                 diff, invoices, admins;
END $$;
