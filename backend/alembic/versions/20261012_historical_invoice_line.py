"""historical_invoice_line: the last invoice whose payment state predates recorded evidence (PAYSTATE-001)

SCHEMA + DATA, written once.

Payment evidence -- the payment row, the gold attribution -- has been recorded
since 24 Sep 2026 (gold_attribution_boundary.captured_at). Invoices before it
had their state written once, with no evidence; a recompute lowered them (72
on the 12 Oct backup). The line is the highest invoice id dated before the
boundary was captured -- stored, as the voucher boundary is, never derived per
read. A back-dated invoice created later and dated before the boundary lifts
the line to its id: it is then protected from lowering on missing evidence,
which its recorded rows make harmless.

Idempotent: adds the column if missing; sets it only where it is NULL.

IMPACT: one column and one value on gold_attribution_boundary. No invoice,
entry or balance changes; InvoicePaymentStateService reads it. Downgrade
drops the column.

Revision ID: 20261012_historical_invoice_line
Revises: 20261012_account_type_spelled_once
Create Date: 2026-10-12
"""
from alembic import op
import sqlalchemy as sa

revision = '20261012_historical_invoice_line'
down_revision = '20261012_account_type_spelled_once'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    columns = {c['name'] for c in sa.inspect(bind).get_columns('gold_attribution_boundary')}
    if 'max_historical_invoice_id' not in columns:
        op.add_column('gold_attribution_boundary', sa.Column('max_historical_invoice_id', sa.Integer(), nullable=True))
    set_ = bind.execute(sa.text(
        'UPDATE gold_attribution_boundary b SET max_historical_invoice_id = '
        '(SELECT max(i.id) FROM invoice i WHERE i.date < b.captured_at) '
        'WHERE b.max_historical_invoice_id IS NULL')).rowcount
    if set_:
        line = bind.execute(sa.text('SELECT max_historical_invoice_id FROM gold_attribution_boundary '
                                    'ORDER BY id LIMIT 1')).scalar()
        print(f'[historical_invoice_line] the last historical invoice: {line}')


def downgrade():
    op.drop_column('gold_attribution_boundary', 'max_historical_invoice_id')
