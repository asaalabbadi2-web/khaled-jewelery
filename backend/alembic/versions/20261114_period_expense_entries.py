"""period_expense: its month entries one a month, its edits recorded (ADR-090, phase 4)

A partial unique index on journal_entry: one entry for each period expense and
month, one reclass for each month (law 6) -- held by the database, not only by
the run's own check. And period_expense_revision: each edit, what it changed,
why, by whom (law 7). No row written.

Revision ID: 20261114_period_expense_entries
Revises: 20261114_period_expense
Create Date: 2026-11-14
"""
import sqlalchemy as sa
from alembic import op

revision = '20261114_period_expense_entries'
down_revision = '20261114_period_expense'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    if 'period_expense_revision' not in sa.inspect(bind).get_table_names():
        op.create_table(
            'period_expense_revision',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('period_expense_id', sa.Integer(), sa.ForeignKey('period_expense.id'), nullable=False, index=True),
            sa.Column('reason', sa.Text(), nullable=False),
            sa.Column('before', sa.Text(), nullable=False),
            sa.Column('after', sa.Text(), nullable=False),
            sa.Column('changed_by', sa.String(length=100), nullable=False),
            sa.Column('changed_at', sa.DateTime(), nullable=False),
        )
    op.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS uq_period_expense_entry_month
        ON journal_entry (reference_type, reference_id, reference_number)
        WHERE reference_type IN ('period_expense', 'period_expense_reclass') AND is_deleted = false
    """)


def downgrade():
    op.execute('DROP INDEX IF EXISTS uq_period_expense_entry_month')
    if 'period_expense_revision' in sa.inspect(op.get_bind()).get_table_names():
        op.drop_table('period_expense_revision')
