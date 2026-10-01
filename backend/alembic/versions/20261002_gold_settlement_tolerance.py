"""gold_settlement_tolerance: the settings' fixed gold settlement margin (the owner, 2 Oct 2026)

A gold difference within a fixed margin -- grams of the main karat, more or
less -- counts as settled (the owner: a fixed number, not a percent). Converting
between karats rounds, and scale weights differ by hundredths; with 0.005 g of
slack an invoice stayed «partially paid» over a thousandth of a gram.

ADDITIVE AND BEHAVIOUR-CHANGING ONLY WHERE MEANT: one nullable float column on
settings, server default 0.05 g. No backfill; an invoice's status
changes only when it is next recomputed (a payment, an attribution, posting).
Idempotent: backend/app.py may have created them already.

Revision ID: 20261002_gold_settlement_tolerance
Revises: 20261001_posted_entry_immutable
Create Date: 2026-10-02
"""
from alembic import op
import sqlalchemy as sa

revision = '20261002_gold_settlement_tolerance'
down_revision = '20261001_posted_entry_immutable'
branch_labels = None
depends_on = None

COLUMNS = (
    ('gold_settlement_tolerance_grams', '0.05'),
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
