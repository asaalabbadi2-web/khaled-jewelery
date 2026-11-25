"""An append-only log -- in the database itself (ADR-102, ADR-103).

A record of who changed what -- a setting, a user's permissions -- is the one
the owner reads after the fact: a row once written is never edited or
deleted, from any path, raw SQL and TRUNCATE included. The one exception is a
system reset or wipe, which opens the posted-entry trigger the same way,
through the setting it reads (posted_entry_trigger.py).

One definition for every such log; the migrations and the test database's DDL
both read it, so production and tests carry one text.
"""

from posted_entry_trigger import PURGE_SETTING


def install_sql(table: str) -> str:
    fn = f'yg_{table}_append_only'
    return f"""
CREATE OR REPLACE FUNCTION {fn}() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION '{table} is append-only: % refused', TG_OP
        USING ERRCODE = 'check_violation';
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_{table}_append_only ON {table};
CREATE TRIGGER trg_{table}_append_only
    BEFORE UPDATE OR DELETE ON {table}
    FOR EACH ROW EXECUTE FUNCTION {fn}();

DROP TRIGGER IF EXISTS trg_{table}_no_truncate ON {table};
CREATE TRIGGER trg_{table}_no_truncate
    BEFORE TRUNCATE ON {table}
    FOR EACH STATEMENT EXECUTE FUNCTION {fn}();
"""


def drop_sql(table: str) -> str:
    return f"""
DROP TRIGGER IF EXISTS trg_{table}_no_truncate ON {table};
DROP TRIGGER IF EXISTS trg_{table}_append_only ON {table};
DROP FUNCTION IF EXISTS yg_{table}_append_only();
"""
