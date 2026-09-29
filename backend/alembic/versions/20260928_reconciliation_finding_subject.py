"""reconciliation_findings: a subject and a magnitude per finding

ReconciliationFinding was designed as "one source of truth for all operational
gaps", but could hold only one finding per KIND -- enough for STALE_SETTLEMENT,
not for a check that must say WHICH safe box drifts or WHICH entry is orphaned.

subject_key names what a finding is about ('safe_box:38', 'journal_entry:7413',
'voucher:4309'); metric is its magnitude at detection, so a change is visible.
A partial unique index allows at most one OPEN finding per (kind, subject).

ADDITIVE AND BEHAVIOUR-NEUTRAL: two nullable columns and an index. Existing
rows keep NULL in both, and the existing per-kind finding is unaffected. No
backfill. Writes happen only from the new report-only jobs.

Revision ID: 20260928_rf_subject
Revises: 20260925_settlement_reason_limits
Create Date: 2026-09-28
"""
from alembic import op
import sqlalchemy as sa

revision = '20260928_rf_subject'
down_revision = '20260925_settlement_reason_limits'
branch_labels = None
depends_on = None

TABLE = 'reconciliation_findings'
INDEX = 'uq_rf_open_subject'


def upgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)
    if TABLE not in set(inspector.get_table_names()):
        # Created from the model by db.create_all() on a fresh database; nothing
        # to converge here.
        return
    existing = {c['name'] for c in inspector.get_columns(TABLE)}
    if 'subject_key' not in existing:
        op.add_column(TABLE, sa.Column('subject_key', sa.String(length=120), nullable=True))
    if 'metric' not in existing:
        op.add_column(TABLE, sa.Column('metric', sa.Float(), nullable=True))
    if INDEX not in {i['name'] for i in inspector.get_indexes(TABLE)}:
        op.create_index(
            INDEX, TABLE, ['kind', 'subject_key'], unique=True,
            postgresql_where=sa.text('resolved_at IS NULL AND subject_key IS NOT NULL'),
        )


def downgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)
    if TABLE not in set(inspector.get_table_names()):
        return
    if INDEX in {i['name'] for i in inspector.get_indexes(TABLE)}:
        op.drop_index(INDEX, table_name=TABLE)
    existing = {c['name'] for c in inspector.get_columns(TABLE)}
    if 'metric' in existing:
        op.drop_column(TABLE, 'metric')
    if 'subject_key' in existing:
        op.drop_column(TABLE, 'subject_key')
