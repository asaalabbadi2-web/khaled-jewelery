"""finding_acceptance: the owner accepts a finding that is true and stays true (stage 4, 3 Oct 2026)

JE-00851 (3,600, Tamara) is posted and its voucher 526 is gone; the owner
confirmed the money is in the bank. The finding is true and will stay true,
so it is accepted -- open, counted every night, out of the news -- rather than
resolved by hand and reopened the next night. A magnitude that moves opens a
new finding nobody has accepted (services/books_invariants.accept_finding).

ADDITIVE: three nullable columns on reconciliation_findings. No backfill: no
finding is accepted until the owner accepts it. Idempotent.

Revision ID: 20261003_finding_acceptance
Revises: 20261002_accountant_approval_limit
Create Date: 2026-10-03
"""
from alembic import op
import sqlalchemy as sa

revision = '20261003_finding_acceptance'
down_revision = '20261002_accountant_approval_limit'
branch_labels = None
depends_on = None

COLUMNS = (
    ('accepted_at', sa.DateTime()),
    ('accepted_by', sa.String(100)),
    ('accepted_reason', sa.Text()),
)


def upgrade():
    existing = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('reconciliation_findings')}
    for name, type_ in COLUMNS:
        if name not in existing:
            op.add_column('reconciliation_findings', sa.Column(name, type_, nullable=True))


def downgrade():
    existing = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('reconciliation_findings')}
    for name, _ in COLUMNS:
        if name in existing:
            op.drop_column('reconciliation_findings', name)
