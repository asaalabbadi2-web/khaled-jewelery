"""The scheduled backup produces an archive that holds the database.

Since the July 2026 routes migration the scheduled path had raised ImportError
on every run -- it imported its helpers from `routes`, where they no longer
live -- and run_backup_now() caught it and printed one line. Nothing tested the
path, so nothing noticed: even with automatic backups switched on, none would
have been written (BACKUP-001). The manual backup, which lives next to those
helpers in routes/system.py, kept working and hid the difference.

The suite runs on SQLite, so this drives the SQLite branch; the PostgreSQL
branch builds its command in routes/system.py, covered by
test_postgres_backup_restore_helpers.py, and is rehearsed end to end on a
production copy with the pg_dump the image ships.

Run:
    python -m pytest tests/test_scheduled_backup.py -v
"""
import json
import sqlite3
import zipfile

from app import app as flask_app


def test_the_scheduled_backup_writes_an_archive_that_holds_the_database(tmp_path, monkeypatch):
    from backup_scheduler import BackupScheduler

    monkeypatch.setenv('BACKUP_DIR', str(tmp_path))
    with flask_app.app_context():
        archive = BackupScheduler(flask_app)._create_backup_zip()

    assert archive is not None and archive.exists(), 'no archive was written'
    with zipfile.ZipFile(archive) as z:
        assert {'database.sqlite', 'metadata.json'} <= set(z.namelist())
        meta = json.loads(z.read('metadata.json'))
        z.extract('database.sqlite', tmp_path / 'restored')
    assert meta['db_backend'] == 'sqlite' and meta['format'] == 'sqlite_file'

    restored = sqlite3.connect(tmp_path / 'restored' / 'database.sqlite')
    tables = {row[0] for row in restored.execute("select name from sqlite_master where type='table'")}
    restored.close()
    assert {'journal_entry', 'journal_entry_line', 'invoice', 'voucher', 'account'} <= tables


def test_the_run_the_scheduler_calls_reports_success_not_a_swallowed_error(tmp_path, monkeypatch, capsys):
    """run_backup_now() catches everything and prints; the print is the only trace."""
    from backup_scheduler import BackupScheduler

    monkeypatch.setenv('BACKUP_DIR', str(tmp_path))
    BackupScheduler(flask_app).run_backup_now()
    out = capsys.readouterr().out
    assert '❌' not in out, out
    assert list(tmp_path.glob('yasargold-backup-*.zip')), out
