"""account_is_active: an account can be deactivated -- it keeps its entries, takes no new one (ADR-043, phase 1)

ADDITIVE.

Adds account.is_active BOOLEAN NOT NULL DEFAULT true -- every existing account
stays active -- and the trigger that refuses a new journal line on a
deactivated account, against raw SQL too (backend/account_status_trigger.py,
shared with the test database's DDL). Lines already on an account are not
touched, and may still change.

Idempotent, as the house's column migrations are: the app's start-up column
sync may add the column first (nullable) -- then it is filled and made NOT NULL.

IMPACT: none on existing data. Downgrade drops the trigger and the column.

Revision ID: 20261011_account_is_active
Revises: 20261008_payment_types_on_evidence
Create Date: 2026-10-11
"""
import os
import sys

from alembic import op
import sqlalchemy as sa

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from account_status_trigger import DROP_SQL, INSTALL_SQL  # noqa: E402

revision = '20261011_account_is_active'
down_revision = '20261008_payment_types_on_evidence'
branch_labels = None
depends_on = None


def _columns(bind):
    return {c['name'] for c in sa.inspect(bind).get_columns('account')}


def upgrade():
    bind = op.get_bind()
    if 'is_active' not in _columns(bind):
        op.add_column('account', sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()))
    else:
        # The app's start-up column sync (schema_guard.ensure_all_model_columns) may
        # have added it first -- nullable, DEFAULT TRUE: made what this migration makes.
        op.execute('UPDATE account SET is_active = TRUE WHERE is_active IS NULL')
        op.alter_column('account', 'is_active', existing_type=sa.Boolean(), nullable=False,
                        server_default=sa.true())
    if bind.dialect.name == 'postgresql':
        op.execute(INSTALL_SQL)


def downgrade():
    bind = op.get_bind()
    if bind.dialect.name == 'postgresql':
        op.execute(DROP_SQL)
    if 'is_active' in _columns(bind):
        op.drop_column('account', 'is_active')
