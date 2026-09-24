"""invoice.gold_settlement_tracked — the forward-only line for gold-aware status

Phase B. An invoice's payment status is about to mean "cash settled AND gold
settled", and this column says which invoices that rule may speak about.

Backfilled False for everything that exists. That is a fact rather than a
shortcut: payment intent was never recorded for those invoices, so their gold
side is UNTRACKED, not unsettled. Measured on real data before shipping — of
149 invoices carrying a gold obligation, only 21 had any attributable
settlement and 121 had none at all, while attribution covered just 17.9% of
25,269 g. Applying the new rule retroactively would therefore have marked
genuinely settled invoices unpaid, including suppliers sitting at a zero
ledger balance. The information to do better does not exist: 0 of 113
historical gold vouchers ever named an invoice.

New purchase invoices are created with it True by routes/invoices.py.

Write-once by contract: no normal operation may flip an invoice False -> True,
since that would make the invoice's meaning depend on when someone happened to
attach a payment to it. A ratchet test enforces that no code outside the
creation path assigns it.

Revision ID: 20260924_invoice_gold_tracked
Revises: 20260924_voucher_invoice_gold_attr
Create Date: 2026-09-24
"""
from alembic import op
import sqlalchemy as sa

revision = '20260924_invoice_gold_tracked'
down_revision = '20260924_voucher_invoice_gold_attr'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    columns = {c['name'] for c in sa.inspect(conn).get_columns('invoice')}
    if 'gold_settlement_tracked' not in columns:
        op.add_column(
            'invoice',
            sa.Column(
                'gold_settlement_tracked', sa.Boolean(),
                nullable=False, server_default='false',
            ),
        )


def downgrade():
    conn = op.get_bind()
    columns = {c['name'] for c in sa.inspect(conn).get_columns('invoice')}
    if 'gold_settlement_tracked' in columns:
        op.drop_column('invoice', 'gold_settlement_tracked')
