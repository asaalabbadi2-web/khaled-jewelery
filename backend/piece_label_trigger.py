"""A label's history is never erased -- in the database itself (ADR-097 law 11; the owner, 20 Nov 2026).

«سجلات المحاولات والبطاقات الملغاة محفوظة وغير قابلة للمحو التشغيلي»:
- a piece's tag, active or stopped, is never deleted; a stopped one is not
  changed (its stop and its reason are its history);
- a print job is never deleted;
- a print attempt is never deleted, and not changed once finished.
The jobs and attempts are the audit itself (ADR-097 §3): no second log.

The one exception is a system reset or wipe, inside
journal_entry_guard.system_purge() -- its transaction-local setting, as the
posted entry's trigger (posted_entry_trigger.py).

No imports: the migration and the test database's DDL both read this text, so
production and tests carry one definition.
"""

PURGE_SETTING = 'yasargold.system_purge'

INSTALL_SQL = f"""
CREATE OR REPLACE FUNCTION yg_label_history_kept() RETURNS trigger AS $$
BEGIN
    IF coalesce(current_setting('{PURGE_SETTING}', true), '') = 'on' THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '% row % is a label''s history: it is not deleted', TG_TABLE_NAME, OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    -- nested: a record's field is read only on its own table's rows
    IF TG_TABLE_NAME = 'piece_tag' THEN
        IF OLD.stopped_at IS NOT NULL THEN
            RAISE EXCEPTION 'piece_tag % is stopped: its history is not changed', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF TG_TABLE_NAME = 'print_attempt' THEN
        IF OLD.finished_at IS NOT NULL THEN
            RAISE EXCEPTION 'print_attempt % is finished: it is not changed', OLD.id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;
"""

TABLE_SQL = {
    table: f"""
DROP TRIGGER IF EXISTS trg_{table}_history_kept ON {table};
CREATE TRIGGER trg_{table}_history_kept
    BEFORE DELETE{' OR UPDATE' if table != 'print_job' else ''} ON {table}
    FOR EACH ROW EXECUTE FUNCTION yg_label_history_kept();
"""
    for table in ('piece_tag', 'print_job', 'print_attempt')
}

DROP_SQL = """
DROP TRIGGER IF EXISTS trg_piece_tag_history_kept ON piece_tag;
DROP TRIGGER IF EXISTS trg_print_job_history_kept ON print_job;
DROP TRIGGER IF EXISTS trg_print_attempt_history_kept ON print_attempt;
DROP FUNCTION IF EXISTS yg_label_history_kept();
"""
