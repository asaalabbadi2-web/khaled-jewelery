"""The settings change log is append-only -- in the database itself (ADR-102).

What a setting was, who changed it and why is the record the owner reads when
VAT, the main karat or a posting rule moved: a row once written is never
edited or deleted, from any path, raw SQL and TRUNCATE included. The one
exception is a system reset or wipe, which opens the posted-entry trigger the
same way, through the setting it reads (posted_entry_trigger.py).

No imports beyond the purge setting's name: the migration and the test
database's DDL both read this text, so production and tests carry one
definition.
"""

from posted_entry_trigger import PURGE_SETTING

INSTALL_SQL = f"""
CREATE OR REPLACE FUNCTION yg_settings_change_append_only() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'settings_change is append-only: % refused', TG_OP
        USING ERRCODE = 'check_violation';
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_settings_change_append_only ON settings_change;
CREATE TRIGGER trg_settings_change_append_only
    BEFORE UPDATE OR DELETE ON settings_change
    FOR EACH ROW EXECUTE FUNCTION yg_settings_change_append_only();

DROP TRIGGER IF EXISTS trg_settings_change_no_truncate ON settings_change;
CREATE TRIGGER trg_settings_change_no_truncate
    BEFORE TRUNCATE ON settings_change
    FOR EACH STATEMENT EXECUTE FUNCTION yg_settings_change_append_only();
"""

DROP_SQL = """
DROP TRIGGER IF EXISTS trg_settings_change_no_truncate ON settings_change;
DROP TRIGGER IF EXISTS trg_settings_change_append_only ON settings_change;
DROP FUNCTION IF EXISTS yg_settings_change_append_only();
"""
