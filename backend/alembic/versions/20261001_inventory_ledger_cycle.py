"""inventory_ledger: a posting cycle, and room for the longest reversal type

The ledger is append-only (ADR-002) and allowed one row per (source line,
movement type): one posting and one reversal per line, ever. An invoice
posted, unposted and posted again could not be written back -- the re-post hit
uq_inventory_ledger_idempotency -- so UNPOST-001's round trip (ADR-034) was
impossible. And movement_type was 30 characters: 'purchase_from_customer_reversal'
is 31, so a customer purchase could never be reversed at all. Neither ever
happened in production: 1,301 rows on the 30 Sep copy, not one reversal.

- movement_type: varchar(30) -> varchar(40).
- cycle: integer NOT NULL DEFAULT 0 -- every existing row is cycle 0.
- uq_inventory_ledger_idempotency gains cycle: (source_type, source_id,
  source_line_id, movement_type, cycle). Existing rows already satisfy it (the
  old constraint was stricter).

ADDITIVE AND NON-DESTRUCTIVE: no value changes, no row is written or removed.
Idempotent: backend/app.py runs db.create_all() and schema_guard may add the
column at import, so each step checks first.

Revision ID: 20261001_inventory_ledger_cycle
Revises: 20260929_scheduler_heartbeats
Create Date: 2026-10-01
"""
from alembic import op
import sqlalchemy as sa

revision = '20261001_inventory_ledger_cycle'
down_revision = '20260929_scheduler_heartbeats'
branch_labels = None
depends_on = None

TABLE = 'inventory_ledger'
UQ = 'uq_inventory_ledger_idempotency'
OLD_COLS = ['source_type', 'source_id', 'source_line_id', 'movement_type']
NEW_COLS = OLD_COLS + ['cycle']


def _uq_columns(inspector):
    for uq in inspector.get_unique_constraints(TABLE):
        if uq['name'] == UQ:
            return list(uq['column_names'])
    return None


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if TABLE not in set(inspector.get_table_names()):
        return
    cols = {c['name']: c for c in inspector.get_columns(TABLE)}

    length = getattr(cols['movement_type']['type'], 'length', None)
    if length is not None and length < 40:
        op.alter_column(TABLE, 'movement_type', type_=sa.String(length=40),
                        existing_type=sa.String(length=length), existing_nullable=False)

    if 'cycle' not in cols:
        op.add_column(TABLE, sa.Column('cycle', sa.Integer(), nullable=False, server_default='0'))

    current = _uq_columns(sa.inspect(op.get_bind()))
    if current != NEW_COLS:
        if current is not None:
            op.drop_constraint(UQ, TABLE, type_='unique')
        op.create_unique_constraint(UQ, TABLE, NEW_COLS)


def downgrade():
    # Refused if any line was posted in more than one cycle: the old constraint
    # cannot hold those rows, and dropping them would rewrite history.
    bind = op.get_bind()
    multi = bind.execute(sa.text(f'select count(*) from {TABLE} where cycle > 0')).scalar()
    if multi:
        raise RuntimeError(f'{multi} inventory_ledger rows are in a later posting cycle; '
                           'the one-row-per-line constraint cannot be restored without deleting them')
    op.drop_constraint(UQ, TABLE, type_='unique')
    op.create_unique_constraint(UQ, TABLE, OLD_COLS)
    op.drop_column(TABLE, 'cycle')
    long_types = bind.execute(sa.text(f'select count(*) from {TABLE} where length(movement_type) > 30')).scalar()
    if not long_types:
        op.alter_column(TABLE, 'movement_type', type_=sa.String(length=30),
                        existing_type=sa.String(length=40), existing_nullable=False)
