"""add payment_method_id to office_reservation

Phase 9C: office reservation deposits are real payments (real Voucher +
JournalEntry + SafeBoxTransaction) but could not safely become a real
InvoicePayment at settlement time because payment_method_id (a NOT NULL
column on invoice_payment) was never captured anywhere in the reservation
creation flow — it resolved a raw safe_box_id directly, bypassing
PaymentMethod entirely (see Phase 8A/8B discovery).

This column is the fix: captured at creation time (now required whenever
paid_amount > 0), read again at settlement time to build the real
InvoicePayment row.

Nullable, no backfill: every existing reservation predates this column
and stays NULL — the same choice already made for
journal_entry_line.source_voucher_id and invoice_payment.source_voucher_id
(see those columns' own migrations). A legacy reservation with a deposit
but a NULL payment_method_id is refused at settlement time with an
explicit error rather than guessed — see settle_office_reservation.

Revision ID: 20260920_add_payment_method_id_or
Revises: 20260920_add_source_voucher_id_ip
Create Date: 2026-09-20
"""
from alembic import op
import sqlalchemy as sa

revision = '20260920_add_payment_method_id_or'
down_revision = '20260920_add_source_voucher_id_ip'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)

    columns = {c['name'] for c in inspector.get_columns('office_reservation')}
    has_column = 'payment_method_id' in columns

    foreign_keys = inspector.get_foreign_keys('office_reservation')
    has_fk = any(
        fk.get('referred_table') == 'payment_method'
        and fk.get('constrained_columns') == ['payment_method_id']
        for fk in foreign_keys
    )

    with op.batch_alter_table('office_reservation', schema=None) as batch_op:
        if not has_column:
            batch_op.add_column(sa.Column('payment_method_id', sa.Integer(), nullable=True))
        if not has_fk:
            batch_op.create_foreign_key(
                'fk_office_reservation_payment_method',
                'payment_method',
                ['payment_method_id'],
                ['id'],
            )

    print(
        f"[payment_method_id/office_reservation migration] column existed={has_column}, "
        f"fk existed={has_fk} — nothing backfilled, no existing row touched."
    )


def downgrade():
    with op.batch_alter_table('office_reservation', schema=None) as batch_op:
        batch_op.drop_constraint('fk_office_reservation_payment_method', type_='foreignkey')
        batch_op.drop_column('payment_method_id')
