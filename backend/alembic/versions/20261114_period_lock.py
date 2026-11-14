"""period_lock: a closed month takes no entry (ADR-090, law 9)

The table is the lock's log -- one row for each move, the last row the lock --
and the triggers hold it in the database: no entry nor line written, changed
or deleted in a closed month, and no row of the log changed or deleted. The
SQL lives in backend/period_lock_trigger.py, shared with the test database's
DDL.

No row is written: the books stay open until the owner closes October 2026,
after the 2026 period-expense tool (ADR-090, phases 8-10). Idempotent: CREATE
IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS.

Revision ID: 20261114_period_lock
Revises: 20261111_return_line_original
Create Date: 2026-11-14
"""
import os
import sys

import sqlalchemy as sa
from alembic import op

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from period_lock_trigger import DROP_SQL, ENTRY_SQL, LOG_SQL  # noqa: E402

revision = '20261114_period_lock'
down_revision = '20261111_return_line_original'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    if 'period_lock' not in sa.inspect(bind).get_table_names():
        op.create_table(
            'period_lock',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('closed_through', sa.Date(), nullable=True),
            sa.Column('reason', sa.Text(), nullable=False),
            sa.Column('changed_by', sa.String(length=100), nullable=False),
            sa.Column('changed_at', sa.DateTime(), nullable=False),
        )
    if bind.dialect.name != 'postgresql':
        return
    op.execute(ENTRY_SQL)
    op.execute(LOG_SQL)


def downgrade():
    bind = op.get_bind()
    if bind.dialect.name == 'postgresql':
        op.execute(DROP_SQL)
    if 'period_lock' in sa.inspect(bind).get_table_names():
        op.drop_table('period_lock')
