#!/usr/bin/env python3
"""Reset database chart of accounts to the canonical standard JSON.

This is intentionally destructive because accounts are referenced by many rows.
The safest approach is a full wipe + import.

What it does:
- Creates a timestamped backup copy of the current SQLite DB file (when using sqlite).
- Runs the existing wipe+import routine using exports/accounts_standard_220126.json.

Usage:
  cd backend
  python devtools/reset_to_standard_coa.py --yes

Notes:
- Requires DATABASE_URL to point at the intended DB.
- Will delete journal entries, vouchers, safeboxes, mappings, etc (same as wipe_and_import_accounts_from_json.py).
"""

from __future__ import annotations

import argparse
import os
import shutil
from datetime import datetime
from pathlib import Path


def _sqlite_db_path_from_url(url: str) -> str | None:
    if not url:
        return None
    if not url.startswith('sqlite:'):
        return None

    # Examples:
    # sqlite:///../app.db  -> ../app.db
    # sqlite:////abs/path -> /abs/path
    raw = url[len('sqlite:'):]
    if raw.startswith('////'):
        return raw[3:]
    if raw.startswith('///'):
        return raw[3:]
    if raw.startswith('//'):
        return raw[2:]
    return raw


def main() -> int:
    parser = argparse.ArgumentParser(description='Backup and reset DB to standard COA JSON')
    parser.add_argument('--yes', action='store_true', help='Confirm destructive reset')
    args = parser.parse_args()

    if not args.yes:
        raise SystemExit('Refusing to reset without --yes')

    backend_dir = Path(__file__).resolve().parents[1]
    repo_dir = backend_dir.parent
    json_path = (repo_dir / 'exports' / 'accounts_standard_220126.json').resolve()

    if not json_path.exists():
        raise SystemExit(f'Standard COA JSON not found: {json_path}')

    db_url = os.getenv('DATABASE_URL', '')
    db_path = _sqlite_db_path_from_url(db_url)

    # Resolve relative sqlite paths relative to backend/instance (Flask default) or cwd.
    # In this repo we standardize DATABASE_URL=sqlite:///../app.db, so cwd=backend is fine.
    backup_done = False
    if db_path:
        candidate = (backend_dir / db_path).resolve() if not str(db_path).startswith('/') else Path(db_path).resolve()
        if candidate.exists():
            backups_dir = (backend_dir / 'backups')
            backups_dir.mkdir(parents=True, exist_ok=True)
            ts = datetime.now().strftime('%Y%m%d-%H%M%S')
            backup_path = backups_dir / f'{candidate.name}.{ts}.bak'
            shutil.copy2(candidate, backup_path)
            print(f'✅ DB backup created: {backup_path}')
            backup_done = True
        else:
            print(f'⚠️  SQLite DB file not found for backup at: {candidate}')
    else:
        print('⚠️  Non-sqlite DATABASE_URL; skipping automatic DB backup')

    # Run wipe+import
    from subprocess import check_call

    script = (backend_dir / 'wipe_and_import_accounts_from_json.py').resolve()
    check_call([
        str(script),
        '--file',
        str(json_path),
        '--wipe',
        '--yes',
    ], cwd=str(backend_dir))

    if backup_done:
        print('ℹ️  If anything looks wrong, restore from backend/backups/*.bak')

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
