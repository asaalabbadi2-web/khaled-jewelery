"""add source_voucher_id to invoice_payment

Fixes a correctness bug in InvoicePaymentStateService: excluding a cancelled
payment from an invoice's paid total was done by joining
SafeBoxTransaction.ref_id to Voucher.id — but ref_id is not a reliable
Voucher reference everywhere. The three receipt-creating paths write
ref_id=voucher.id; the two payment-method-correction paths write
ref_id=invoice_payment.id instead (an older convention). The two id spaces
can coincide by pure numeric accident, and a real example of this was found
in a restored production copy: SafeBoxTransaction.ref_id=444 meant
"InvoicePayment #444" under the old convention, while Voucher #444 genuinely
exists and belongs to a completely different invoice.

This column is the direct fix: a real FK from InvoicePayment to the voucher
that actually created it, populated only where that is literally true.

Nullable, no backfill: every existing row predates this column and stays
NULL, which InvoicePaymentStateService now treats as "not excludable by this
mechanism" — the same choice already made for
journal_entry_line.source_voucher_id (see that column's own migration).

Revision ID: 20260920_add_source_voucher_id_ip
Revises: 20260920_add_source_voucher_id
Create Date: 2026-09-20
"""
from alembic import op
import sqlalchemy as sa

revision = '20260920_add_source_voucher_id_ip'
down_revision = '20260920_add_source_voucher_id'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)

    # Idempotent: db.create_all() at application boot may have already
    # created this column from the model before this migration ever runs —
    # the established pattern in this repo (see the SAD migration's own
    # PRE-CHECK, and this same reasoning in the sibling
    # journal_entry_line.source_voucher_id migration).
    columns = {c['name'] for c in inspector.get_columns('invoice_payment')}
    has_column = 'source_voucher_id' in columns

    foreign_keys = inspector.get_foreign_keys('invoice_payment')
    has_fk = any(
        fk.get('referred_table') == 'voucher'
        and fk.get('constrained_columns') == ['source_voucher_id']
        for fk in foreign_keys
    )

    with op.batch_alter_table('invoice_payment', schema=None) as batch_op:
        if not has_column:
            batch_op.add_column(sa.Column('source_voucher_id', sa.Integer(), nullable=True))
        if not has_fk:
            # No ondelete clause: a cancelled/deleted voucher must never
            # cascade-delete the payment record referencing it, and must stay
            # queryable (its status is exactly what the exclusion checks).
            batch_op.create_foreign_key(
                'fk_invoice_payment_source_voucher',
                'voucher',
                ['source_voucher_id'],
                ['id'],
            )

    print(
        f"[source_voucher_id/invoice_payment migration] column existed={has_column}, "
        f"fk existed={has_fk} — nothing backfilled, no existing row touched."
    )


def downgrade():
    with op.batch_alter_table('invoice_payment', schema=None) as batch_op:
        batch_op.drop_constraint('fk_invoice_payment_source_voucher', type_='foreignkey')
        batch_op.drop_column('source_voucher_id')
