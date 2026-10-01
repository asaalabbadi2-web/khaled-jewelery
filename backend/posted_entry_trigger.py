"""A posted journal entry is never deleted, nor soft-deleted -- in the database itself (UNPOST-001 U3).

The owner's rule (1 Oct 2026): a posted manual entry is corrected by a
reversing entry, never deleted; a document's entry goes only with its document,
through the document's operation. This trigger is the last line: it holds
against any code path, raw SQL and TRUNCATE included. Unposting first is the
document operation's business (journal_entry_guard keeps entry and document
consistent at commit); the trigger only guards the posted row.

The one exception is a system reset or wipe (routes/system.py), and only
inside journal_entry_guard.system_purge(), which sets the transaction-local
setting below; tests/test_posted_entry_immutable.py fails if any other runtime
code uses it.

No imports: the migration and the test database's DDL both read this text, so
production and tests carry one definition.
"""

PURGE_SETTING = 'yasargold.system_purge'

INSTALL_SQL = f"""
CREATE OR REPLACE FUNCTION yg_posted_entry_immutable() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'journal_entry cannot be truncated outside a system purge'
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' AND coalesce(OLD.is_posted, false) THEN
        RAISE EXCEPTION 'posted journal entry % cannot be deleted: reverse it instead', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'UPDATE' AND coalesce(OLD.is_posted, false)
       AND coalesce(NEW.is_deleted, false) AND NOT coalesce(OLD.is_deleted, false) THEN
        RAISE EXCEPTION 'posted journal entry % cannot be soft-deleted: reverse it instead', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_posted_entry_immutable ON journal_entry;
CREATE TRIGGER trg_posted_entry_immutable
    BEFORE DELETE OR UPDATE ON journal_entry
    FOR EACH ROW EXECUTE FUNCTION yg_posted_entry_immutable();

DROP TRIGGER IF EXISTS trg_posted_entry_no_truncate ON journal_entry;
CREATE TRIGGER trg_posted_entry_no_truncate
    BEFORE TRUNCATE ON journal_entry
    FOR EACH STATEMENT EXECUTE FUNCTION yg_posted_entry_immutable();
"""

DROP_SQL = """
DROP TRIGGER IF EXISTS trg_posted_entry_no_truncate ON journal_entry;
DROP TRIGGER IF EXISTS trg_posted_entry_immutable ON journal_entry;
DROP FUNCTION IF EXISTS yg_posted_entry_immutable();
"""
