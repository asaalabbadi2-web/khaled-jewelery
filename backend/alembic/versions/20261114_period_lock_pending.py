"""period_lock: what waited in the months a move closed, accepted by name (ADR-090, phase 6)

A nullable column on the lock's log: when the owner closes months with
vouchers, entries or invoices still waiting, or a period expense's months not
posted, what was accepted is kept with the move. No row written.

Revision ID: 20261114_period_lock_pending
Revises: 20261114_period_expense_entries
Create Date: 2026-11-14
"""
import sqlalchemy as sa
from alembic import op

revision = '20261114_period_lock_pending'
down_revision = '20261114_period_expense_entries'
branch_labels = None
depends_on = None


def upgrade():
    if 'accepted_pending' not in {c['name'] for c in sa.inspect(op.get_bind()).get_columns('period_lock')}:
        op.add_column('period_lock', sa.Column('accepted_pending', sa.Text(), nullable=True))


def downgrade():
    if 'accepted_pending' in {c['name'] for c in sa.inspect(op.get_bind()).get_columns('period_lock')}:
        op.drop_column('period_lock', 'accepted_pending')
