"""Automatic backup scheduler (server-side).

Reads configuration from the Settings row:
- backup_auto_enabled: bool
- backup_auto_mode: "interval" | "daily"
- backup_auto_interval_minutes: int
- backup_auto_time: "HH:MM" (server local time; used only for daily mode)
- backup_retention_count: int (keep last N backups)

Backups are stored on the server file system (not on the client device).
For client-side backups (USB/cloud on the user's device), use the download
endpoint from the Flutter UI and save/share the file.

Note: Designed for single-process deployments (dev mode). In multi-worker
setups you should run a singleton scheduler service to avoid duplicates.
"""

from __future__ import annotations

import os
import time
from datetime import datetime
from pathlib import Path
from threading import Thread

import schedule

from models import Settings, db


class BackupScheduler:
    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._last_config: tuple[str, str, str, str, str] | None = None
        self._scheduler = schedule.Scheduler()

    def _read_config(self) -> tuple[bool, str, int, str, int]:
        with self.app.app_context():
            row = Settings.query.first()
            if not row:
                return False, "daily", 1440, "02:00", 7

            enabled = bool(getattr(row, "backup_auto_enabled", False))
            mode = (getattr(row, "backup_auto_mode", None) or "daily").strip().lower()

            interval_raw = getattr(row, "backup_auto_interval_minutes", None)
            try:
                interval_minutes = int(interval_raw) if interval_raw is not None else 1440
            except Exception:
                interval_minutes = 1440
            if interval_minutes < 1:
                interval_minutes = 1
            if interval_minutes > 10080:
                interval_minutes = 10080

            at_time = (getattr(row, "backup_auto_time", None) or "02:00").strip()

            retention_raw = getattr(row, "backup_retention_count", None)
            try:
                retention = int(retention_raw) if retention_raw is not None else 7
            except Exception:
                retention = 7
            if retention < 1:
                retention = 1
            if retention > 365:
                retention = 365

            return enabled, mode, interval_minutes, at_time, retention

    def _backup_dir(self) -> Path:
        # Can be overridden for Docker/production.
        configured = os.getenv("BACKUP_DIR")
        if configured and configured.strip():
            return Path(configured).expanduser().resolve()
        return (Path(__file__).parent / "backups").resolve()

    def _prune_old_backups(self, retention: int) -> None:
        try:
            backup_dir = self._backup_dir()
            if not backup_dir.exists():
                return
            backups = sorted(
                backup_dir.glob("yasargold-backup-*.zip"),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            for p in backups[retention:]:
                try:
                    p.unlink(missing_ok=True)
                except Exception:
                    pass
        except Exception:
            pass

    def _create_backup_zip(self) -> Path | None:
        # Import lazily to avoid circular imports. From routes.system, where these
        # live since the July 2026 routes migration: importing them from `routes`
        # raised ImportError on every scheduled run until 2026-09-29 (BACKUP-001).
        from routes.system import (
            _create_postgres_backup_to_file,
            _create_sqlite_backup_to_file,
            _is_postgres_database,
            _is_sqlite_database,
        )

        backup_dir = self._backup_dir()
        backup_dir.mkdir(parents=True, exist_ok=True)

        created_at = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        filename = f"yasargold-backup-{created_at}.zip"
        zip_path = backup_dir / filename

        is_pg = _is_postgres_database()
        is_sqlite = _is_sqlite_database()
        if not (is_pg or is_sqlite):
            print("[BackupScheduler] Skipping: unsupported DB backend")
            return None

        tmp_db_path = backup_dir / (f".tmp-{created_at}.dump" if is_pg else f".tmp-{created_at}.sqlite")
        try:
            if is_pg:
                _create_postgres_backup_to_file(str(tmp_db_path))
            else:
                _create_sqlite_backup_to_file(str(tmp_db_path))

            import json
            import zipfile

            meta = {
                "created_at_utc": datetime.utcnow().isoformat() + "Z",
                "db_backend": "postgres" if is_pg else "sqlite",
                "format": "pg_dump_custom" if is_pg else "sqlite_file",
            }

            with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                zf.write(tmp_db_path, arcname=("database.dump" if is_pg else "database.sqlite"))
                zf.writestr("metadata.json", json.dumps(meta, ensure_ascii=False, indent=2))

            return zip_path
        finally:
            try:
                tmp_db_path.unlink(missing_ok=True)
            except Exception:
                pass

    def run_backup_now(self) -> None:
        with self.app.app_context():
            try:
                enabled, mode, interval, at_time, retention = self._read_config()
                zip_path = self._create_backup_zip()
                if zip_path is None:
                    return
                self._prune_old_backups(retention)
                print(f"[BackupScheduler] ✓ Backup created: {zip_path}")
            except Exception as exc:
                try:
                    db.session.rollback()
                except Exception:
                    pass
                print(f"[BackupScheduler] ❌ Backup failed: {exc}")

    def _apply_schedule(self, enabled: bool, mode: str, interval_minutes: int, at_time: str) -> None:
        self._scheduler.clear("backup")
        if not enabled:
            print("[BackupScheduler] Auto-backup disabled")
            return

        normalized = (mode or "daily").strip().lower()
        if normalized == "daily":
            try:
                self._scheduler.every().day.at(at_time).do(self.run_backup_now).tag("backup")
                print(f"[BackupScheduler] Auto-backup enabled daily at {at_time}")
            except Exception as exc:
                print(f"[BackupScheduler] Invalid daily time '{at_time}': {exc}")
            return

        # interval mode
        minutes = int(interval_minutes) if interval_minutes else 1440
        if minutes < 1:
            minutes = 1
        self._scheduler.every(minutes).minutes.do(self.run_backup_now).tag("backup")
        print(f"[BackupScheduler] Auto-backup enabled every {minutes} minute(s)")

    def start(self) -> None:
        if self.is_running:
            print("[BackupScheduler] Scheduler already running")
            return

        self.is_running = True

        def run_loop() -> None:
            enabled, mode, interval, at_time, retention = self._read_config()
            self._last_config = (str(enabled), mode, str(interval), at_time, str(retention))
            self._apply_schedule(enabled, mode, interval, at_time)

            while self.is_running:
                try:
                    enabled_now, mode_now, interval_now, at_time_now, retention_now = self._read_config()
                    fingerprint = (
                        str(enabled_now),
                        mode_now,
                        str(interval_now),
                        at_time_now,
                        str(retention_now),
                    )
                    if self._last_config != fingerprint:
                        self._last_config = fingerprint
                        self._apply_schedule(enabled_now, mode_now, interval_now, at_time_now)
                except Exception as exc:
                    print(f"[BackupScheduler] Config read failed: {exc}")

                self._scheduler.run_pending()
                time.sleep(30)

        Thread(target=run_loop, daemon=True).start()
        print("[BackupScheduler] 🚀 Started")

    def stop(self) -> None:
        self.is_running = False
        self._scheduler.clear("backup")
        print("[BackupScheduler] ⏸️ Stopped")


_scheduler_instance: BackupScheduler | None = None


def get_backup_scheduler(app) -> BackupScheduler:
    global _scheduler_instance
    if _scheduler_instance is None:
        _scheduler_instance = BackupScheduler(app)
    return _scheduler_instance


def start_backup_scheduler(app):
    # Avoid double-start under Werkzeug reloader in debug mode
    if app.debug and os.environ.get("WERKZEUG_RUN_MAIN") != "true":
        return None

    scheduler = get_backup_scheduler(app)
    scheduler.start()
    return scheduler
