"""A deactivated account takes no new journal line -- in the database itself (ADR-043, phase 1).

The session guard in models.py refuses it with a readable error on every ORM
path; this trigger is the last line, against raw SQL too, as a posted entry is
held (posted_entry_trigger.py, ADR-035). A line already on the account stays,
and may be changed (soft-deleted, say) -- only a new line, or a line moved onto
the account, is refused.

No imports: the migration and the test database's DDL both read this text, so
production and tests carry one definition.
"""

INSTALL_SQL = """
CREATE OR REPLACE FUNCTION yg_account_active_for_line() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.account_id IS NOT DISTINCT FROM OLD.account_id THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM account WHERE id = NEW.account_id AND NOT is_active) THEN
        RAISE EXCEPTION 'account % is deactivated: it takes no new entry', NEW.account_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_account_active_for_line ON journal_entry_line;
CREATE TRIGGER trg_account_active_for_line
    BEFORE INSERT OR UPDATE OF account_id ON journal_entry_line
    FOR EACH ROW EXECUTE FUNCTION yg_account_active_for_line();
"""

DROP_SQL = """
DROP TRIGGER IF EXISTS trg_account_active_for_line ON journal_entry_line;
DROP FUNCTION IF EXISTS yg_account_active_for_line();
"""
