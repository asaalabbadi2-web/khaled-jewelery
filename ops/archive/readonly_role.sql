-- A closed year's archive: the database role it signs in with (ADR-044 phase 2).
--
-- The owner, 12 Oct 2026: «نسخة ثانية من النظام للقراءة فقط برابط منفصل، على
-- قاعدة 2026 المقفلة». The archive reads every table and writes none of the
-- books: only what signing in, out and renewing a token write -- the user's
-- last sign-in, his sessions, the audit log, the sign-in attempts. The
-- application refuses every other write as well (ARCHIVE_YEAR,
-- services/fiscal_year); this is the database saying it too, whatever the code.
--
-- Run once, in the closed year's database, as its owner:
--   psql -d <the closed year's database> -v password="'<a strong password>'" -f ops/archive/readonly_role.sql
-- The archive's DATABASE_URL then signs in as archive_reader.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'archive_reader') THEN
        CREATE ROLE archive_reader LOGIN;
    END IF;
END $$;
ALTER ROLE archive_reader PASSWORD :password;

GRANT CONNECT ON DATABASE :"DBNAME" TO archive_reader;
GRANT USAGE ON SCHEMA public TO archive_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM archive_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO archive_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO archive_reader;

-- signing in, out, renewing: nothing of the books
GRANT UPDATE (last_login_at, updated_at) ON app_user TO archive_reader;     -- updated_at: the model's own
GRANT UPDATE (last_login, updated_at) ON users TO archive_reader;            -- the legacy sign-in
GRANT INSERT, UPDATE ON refresh_tokens TO archive_reader;
GRANT INSERT, UPDATE ON session_activity TO archive_reader;                   -- the idle sign-out's clock
GRANT INSERT ON token_blacklist TO archive_reader;                            -- signing out
GRANT INSERT ON audit_logs TO archive_reader;
GRANT INSERT ON login_attempts TO archive_reader;
GRANT USAGE ON SEQUENCE refresh_tokens_id_seq, session_activity_id_seq, token_blacklist_id_seq, audit_logs_id_seq,
    login_attempts_id_seq TO archive_reader;
