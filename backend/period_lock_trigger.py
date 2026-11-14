"""A closed month takes no entry -- in the database itself (ADR-090, law 9).

The last line, as a posted entry is held (posted_entry_trigger.py): it holds
against every code path, raw SQL included. period_lock_guard.py refuses the
same writes earlier, with a readable error, on every ORM path.

The month is closed through the date of the last row of period_lock -- one row
for each move, never changed nor deleted, so the log is the lock. No row, or a
last row with no date: nothing is closed.

Refused at or before that date: a journal entry inserted, updated or deleted;
an update moving an entry's date out of a closed month or into one; a line
inserted, updated or deleted on an entry of a closed month. Drafts too -- a
draft dated in a closed month would post there later.

The one exception is the existing one, by the same setting: a system reset
or wipe, which opens the posted-entry trigger too (posted_entry_trigger.py).

One import, that setting's name, from a module with none: the migration and
the test database's DDL both read this text, so production and tests carry
one definition.
"""

from posted_entry_trigger import PURGE_SETTING

# On journal_entry and journal_entry_line. PL/pgSQL binds period_lock when it
# runs, so this may be installed before that table exists (the tests' create_all).
ENTRY_SQL = f"""
CREATE OR REPLACE FUNCTION yg_closed_through() RETURNS date AS $$
DECLARE
    closed date;
BEGIN
    SELECT closed_through INTO closed FROM period_lock ORDER BY id DESC LIMIT 1;
    RETURN closed;
END
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION yg_period_lock_entry() RETURNS trigger AS $$
DECLARE
    closed date;
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    closed := yg_closed_through();
    IF closed IS NOT NULL THEN
        IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.date::date <= closed THEN
            RAISE EXCEPTION 'period_closed: entry % is dated %, in a month closed through %',
                OLD.id, OLD.date::date, closed USING ERRCODE = 'check_violation';
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.date::date <= closed THEN
            RAISE EXCEPTION 'period_closed: an entry dated %, in a month closed through %',
                NEW.date::date, closed USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION yg_period_lock_line() RETURNS trigger AS $$
DECLARE
    closed date;
    dated date;
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    closed := yg_closed_through();
    IF closed IS NOT NULL THEN
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            SELECT date::date INTO dated FROM journal_entry WHERE id = OLD.journal_entry_id;
            IF dated <= closed THEN
                RAISE EXCEPTION 'period_closed: a line of an entry dated %, in a month closed through %',
                    dated, closed USING ERRCODE = 'check_violation';
            END IF;
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            SELECT date::date INTO dated FROM journal_entry WHERE id = NEW.journal_entry_id;
            IF dated <= closed THEN
                RAISE EXCEPTION 'period_closed: a line of an entry dated %, in a month closed through %',
                    dated, closed USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_period_lock_entry ON journal_entry;
CREATE TRIGGER trg_period_lock_entry
    BEFORE INSERT OR UPDATE OR DELETE ON journal_entry
    FOR EACH ROW EXECUTE FUNCTION yg_period_lock_entry();

DROP TRIGGER IF EXISTS trg_period_lock_line ON journal_entry_line;
CREATE TRIGGER trg_period_lock_line
    BEFORE INSERT OR UPDATE OR DELETE ON journal_entry_line
    FOR EACH ROW EXECUTE FUNCTION yg_period_lock_line();
"""

# On period_lock: a move is a new row; a row is never changed nor deleted.
LOG_SQL = f"""
CREATE OR REPLACE FUNCTION yg_period_lock_log_append_only() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'period_lock is a log: a move is a new row, a row is never changed nor deleted'
        USING ERRCODE = 'check_violation';
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_period_lock_log_append_only ON period_lock;
CREATE TRIGGER trg_period_lock_log_append_only
    BEFORE UPDATE OR DELETE ON period_lock
    FOR EACH ROW EXECUTE FUNCTION yg_period_lock_log_append_only();

DROP TRIGGER IF EXISTS trg_period_lock_log_no_truncate ON period_lock;
CREATE TRIGGER trg_period_lock_log_no_truncate
    BEFORE TRUNCATE ON period_lock
    FOR EACH STATEMENT EXECUTE FUNCTION yg_period_lock_log_append_only();
"""

DROP_SQL = """
DROP TRIGGER IF EXISTS trg_period_lock_log_no_truncate ON period_lock;
DROP TRIGGER IF EXISTS trg_period_lock_log_append_only ON period_lock;
DROP TRIGGER IF EXISTS trg_period_lock_line ON journal_entry_line;
DROP TRIGGER IF EXISTS trg_period_lock_entry ON journal_entry;
DROP FUNCTION IF EXISTS yg_period_lock_log_append_only();
DROP FUNCTION IF EXISTS yg_period_lock_line();
DROP FUNCTION IF EXISTS yg_period_lock_entry();
DROP FUNCTION IF EXISTS yg_closed_through();
"""
