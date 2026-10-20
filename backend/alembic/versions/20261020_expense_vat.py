"""expense_vat: the tax invoice an operating expense was paid with (20 Oct 2026)

SCHEMA, ADDITIVE.

voucher_expense_vat -- one row per voucher whose operating expense carried
VAT (ADR-053; services/expense_vat.py): the VAT, the supplier's name and VAT
number, the invoice's number and date, whether the VAT was recovered on the
voucher's day (ADR-043 rule 1) and the account it was posted to.

IMPACT: a new empty table; no existing row, voucher or entry is touched.
Expense vouchers already posted stay as they were (the owner, 20 Oct 2026).
Downgrade drops the table -- the tax invoices recorded since are lost with it
(the entries keep their VAT lines).

Revision ID: 20261020_expense_vat
Revises: 20261018_card_methods_receive_only
Create Date: 2026-10-20
"""
from alembic import op
import sqlalchemy as sa

revision = '20261020_expense_vat'
down_revision = '20261018_card_methods_receive_only'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'voucher_expense_vat',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('voucher_id', sa.Integer(), sa.ForeignKey('voucher.id', ondelete='CASCADE'), nullable=False),
        sa.Column('amount', sa.Float(), nullable=False),
        sa.Column('supplier_name', sa.String(200), nullable=False),
        sa.Column('supplier_tax_number', sa.String(15), nullable=False),
        sa.Column('invoice_number', sa.String(100), nullable=False),
        sa.Column('invoice_date', sa.Date(), nullable=False),
        sa.Column('recoverable', sa.Boolean(), nullable=False),
        sa.Column('vat_account_id', sa.Integer(), sa.ForeignKey('account.id'), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=False),
    )
    op.create_index('ix_voucher_expense_vat_voucher_id', 'voucher_expense_vat', ['voucher_id'], unique=True)


def downgrade():
    op.drop_index('ix_voucher_expense_vat_voucher_id', table_name='voucher_expense_vat')
    op.drop_table('voucher_expense_vat')
