"""accountant_approval_limit: the amount and weight under which the accountant approves (the owner, 2 Oct 2026)

ADR-036 R4: who creates a voucher does not approve it; the manager approves,
and the accountant approves another's voucher within a limit set in the
settings -- cash in riyals and gold in grams of the main karat. The owner set
the starting limit at zero: the accountant approves nothing until it is set.

ADDITIVE: two nullable float columns on settings, server default 0. No
backfill. Idempotent: backend/app.py may have created them already.

Revision ID: 20261002_accountant_approval_limit
Revises: 20261002_gold_settlement_tolerance
Create Date: 2026-10-02
"""
from alembic import op
import sqlalchemy as sa

revision = '20261002_accountant_approval_limit'
down_revision = '20261002_gold_settlement_tolerance'
branch_labels = None
depends_on = None

COLUMNS = (
    ('accountant_approval_limit_cash', '0'),
    ('accountant_approval_limit_gold_grams', '0'),
)


def upgrade():
    existing = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('settings')}
    for name, default in COLUMNS:
        if name not in existing:
            op.add_column('settings', sa.Column(name, sa.Float(), nullable=True, server_default=default))


def downgrade():
    existing = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('settings')}
    for name, _ in COLUMNS:
        if name in existing:
            op.drop_column('settings', name)
