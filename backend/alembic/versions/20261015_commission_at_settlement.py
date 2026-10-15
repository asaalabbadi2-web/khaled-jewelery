"""commission_at_settlement: every payment method takes its commission at its settlement (COMMISSION-1)

DATA ONLY. The owner (15 Oct 2026): a commission is taken when the bank, Tamara
or Tabby deposit, never at the invoice. The code no longer reads
payment_method.commission_timing; this sets every row to 'settlement' and the
column's default too, so the previous release -- which still reads it --
behaves the same way if it is ever rolled back to. The column itself goes in a
later release, once no deployed code reads it.

Refused when a method at 'invoice' has a commission (a rate or a fixed amount):
its past payments carried their commission at the invoice, and would carry it
again at their settlement. On the 15 Oct 2026 copy the methods at 'invoice'
are نقداً and تحويل, both at rate 0 -- nothing to refuse.

Impact: payment_method.commission_timing on the rows at 'invoice' (2 on
production), and the column's server default. No entry, payment or balance
changes. Downgrade puts the default back to 'invoice'; the rows stay at
'settlement' (at rate 0, the two post the same either way).
"""
from alembic import op
import sqlalchemy as sa

revision = '20261015_commission_at_settlement'
down_revision = '20261015_live_roles'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    charging = bind.execute(sa.text(
        "SELECT id, name FROM payment_method WHERE commission_timing <> 'settlement' "
        "AND (COALESCE(commission_rate, 0) > 0 OR COALESCE(commission_fixed_amount, 0) > 0)")).fetchall()
    if charging:
        raise RuntimeError('COMMISSION-1: methods take a commission at the invoice -- decide how their pending '
                           f'payments settle before this runs: {[(r.id, r.name) for r in charging]}')
    moved = bind.execute(sa.text(
        "UPDATE payment_method SET commission_timing = 'settlement' WHERE commission_timing <> 'settlement' "
        "RETURNING id, name")).fetchall()
    print(f'[commission_at_settlement] moved to settlement: {[(r.id, r.name) for r in moved]}')
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.alter_column('commission_timing', existing_type=sa.String(length=20), existing_nullable=False,
                              server_default='settlement')


def downgrade():
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.alter_column('commission_timing', existing_type=sa.String(length=20), existing_nullable=False,
                              server_default='invoice')
