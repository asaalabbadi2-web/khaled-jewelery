#!/usr/bin/env python3
"""Reset authentication users and create a single admin account.

This script is intended for emergency recovery when you cannot log in.
It will:
- Deactivate all existing `User` and `AppUser` accounts
- Revoke all refresh tokens and clear token blacklist
- Ensure an `admin` account exists with password `admin`

Run from the backend folder (venv) or inside the backend container.

Examples:
  python reset_admin_user.py --yes

Docker Compose:
  docker compose -f docker-compose.prod.images.yml --env-file .env.production run --rm backend \
    python backend/reset_admin_user.py --yes
"""

from __future__ import annotations

import argparse
from datetime import datetime

from app import app, db
from models import AppUser, RefreshToken, TokenBlacklist, User


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Deactivate all users and create admin/admin.')
    parser.add_argument('--yes', action='store_true', help='Skip the safety prompt.')
    parser.add_argument('--username', default='admin', help='Admin username (default: admin).')
    parser.add_argument('--password', default='admin', help='Admin password (default: admin).')
    parser.add_argument('--full-name', default='مدير النظام', help='Admin full name.')
    return parser.parse_args()


def reset_admin(*, username: str, password: str, full_name: str) -> None:
    # 1) Disable all accounts (safer than deleting; avoids FK constraint issues).
    db.session.query(AppUser).update(
        {
            AppUser.is_active: False,
            AppUser.two_factor_enabled: False,
            AppUser.totp_secret: None,
            AppUser.two_factor_verified_at: None,
        },
        synchronize_session=False,
    )
    db.session.query(User).update(
        {
            User.is_active: False,
            User.is_admin: False,
        },
        synchronize_session=False,
    )

    # 2) Revoke/clear sessions.
    db.session.query(RefreshToken).delete(synchronize_session=False)
    db.session.query(TokenBlacklist).delete(synchronize_session=False)

    # 3) Ensure admin AppUser
    app_admin = AppUser.query.filter_by(username=username).first()
    if not app_admin:
        app_admin = AppUser(username=username)
        db.session.add(app_admin)

    app_admin.full_name = full_name
    app_admin.role = 'system_admin'
    app_admin.permissions = None
    app_admin.is_active = True
    app_admin.two_factor_enabled = False
    app_admin.totp_secret = None
    app_admin.two_factor_verified_at = None
    app_admin.last_login_at = None
    app_admin.set_password(password)

    # 4) Ensure legacy User admin (used by some bypass/dev paths)
    legacy_admin = User.query.filter_by(username=username).first()
    if not legacy_admin:
        legacy_admin = User(username=username, full_name=full_name)
        db.session.add(legacy_admin)

    legacy_admin.full_name = full_name
    legacy_admin.is_active = True
    legacy_admin.is_admin = True
    legacy_admin.set_password(password)
    legacy_admin.last_login = None

    db.session.commit()


def main() -> None:
    args = _parse_args()

    if not args.yes:
        print('⚠️  This will deactivate ALL users and set admin credentials.')
        confirmation = input("Type 'RESET_USERS' to continue: ").strip()
        if confirmation != 'RESET_USERS':
            print('Aborted.')
            return

    started = datetime.utcnow()
    with app.app_context():
        reset_admin(username=args.username, password=args.password, full_name=args.full_name)
    elapsed = (datetime.utcnow() - started).total_seconds()

    print('✅ Done.')
    print(f"Admin username: {args.username}")
    print('Admin password: (as provided)')
    print(f'⏱️  Took {elapsed:.2f}s')


if __name__ == '__main__':
    main()
