"""account_is_active: an account can be deactivated -- it keeps its entries, takes no new one (ADR-043, phase 1)

ADDITIVE.

Adds account.is_active BOOLEAN NOT NULL DEFAULT true -- every existing account
stays active -- and the trigger that refuses a new journal line on a
deactivated account, against raw SQL too (backend/account_status_trigger.py,
shared with the test database's DDL). Lines already on an account are not
touched, and may still change.

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


def upgrade():
    op.add_column('account', sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()))
    if op.get_bind().dialect.name == 'postgresql':
        op.execute(INSTALL_SQL)


def downgrade():
    if op.get_bind().dialect.name == 'postgresql':
        op.execute(DROP_SQL)
    op.drop_column('account', 'is_active')
