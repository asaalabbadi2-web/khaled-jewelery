"""A commission's VAT waits for its monthly tax invoice (ADR-101).

Revision ID: 20261125_commission_tax_invoice
Revises: 20261125_coding_rest

Impact -- no data changes; every method claims its commission's VAT at the
settlement, as today, until the owner sets the month it issues monthly tax
invoices from:
- payment_method.tax_invoice_from (NULL for every method).
- payment_method.commission_vat_pending_account_id (NULL; the account is made
  the first time a VAT waits).
- New table commission_tax_invoice (empty).
Downgrade drops all of it (refused by its foreign keys once an invoice or a
pending account exists -- undo them first).
"""
from alembic import op
import sqlalchemy as sa

revision = '20261125_commission_tax_invoice'
down_revision = '20261125_coding_rest'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('payment_method') as batch:
        batch.add_column(sa.Column('tax_invoice_from', sa.Date(), nullable=True))
        batch.add_column(sa.Column('commission_vat_pending_account_id', sa.Integer(), nullable=True))
        batch.create_foreign_key('fk_payment_method_commission_vat_pending_account', 'account',
                                 ['commission_vat_pending_account_id'], ['id'], ondelete='RESTRICT')
    op.create_table(
        'commission_tax_invoice',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('payment_method_id', sa.Integer(),
                  sa.ForeignKey('payment_method.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('period_month', sa.Date(), nullable=False),
        sa.Column('invoice_number', sa.String(60), nullable=False),
        sa.Column('invoice_date', sa.Date(), nullable=False),
        sa.Column('supplier_tax_number', sa.String(15), nullable=False),
        sa.Column('fee_amount', sa.Float(), nullable=False),
        sa.Column('vat_amount', sa.Float(), nullable=False),
        sa.Column('computed_fee', sa.Float(), nullable=False, server_default='0'),
        sa.Column('computed_vat', sa.Float(), nullable=False, server_default='0'),
        sa.Column('rounding_moved', sa.Float(), nullable=False, server_default='0'),
        sa.Column('voucher_id', sa.Integer(), sa.ForeignKey('voucher.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('note', sa.Text(), nullable=True),
        sa.Column('created_by', sa.String(100), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint('payment_method_id', 'period_month', name='uq_commission_tax_invoice_month'),
        sa.CheckConstraint('vat_amount >= 0 AND fee_amount >= 0', name='ck_commission_tax_invoice_amounts'),
    )
    op.create_index('ix_commission_tax_invoice_payment_method_id', 'commission_tax_invoice',
                    ['payment_method_id'])


def downgrade():
    op.drop_index('ix_commission_tax_invoice_payment_method_id', table_name='commission_tax_invoice')
    op.drop_table('commission_tax_invoice')
    with op.batch_alter_table('payment_method') as batch:
        batch.drop_constraint('fk_payment_method_commission_vat_pending_account', type_='foreignkey')
        batch.drop_column('commission_vat_pending_account_id')
        batch.drop_column('tax_invoice_from')
