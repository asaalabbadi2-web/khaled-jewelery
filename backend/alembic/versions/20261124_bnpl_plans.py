"""A payment method's plans, its fee a deposit, a payment's plan, and a deposit confirmed (ADR-100).

Revision ID: 20261124_bnpl_plans
Revises: 20261123_piece_return_tag

Impact -- no data changes; every method stays as it computes today until the
owner sets it in the payment methods' settings («اجعلها شاملة لمثل هكذا وسائل
ويتم ضبطها في الإعدادات»):
- New table payment_method_plan (empty).
- payment_method: deposit_fixed_fee (0), commission_per_order (false),
  deposit_confirmation_required (false), deposit_difference_allowed (10),
  commission_rounding ('half_up'), commission_refundable_rate (0).
- invoice_payment.installments (NULL for every payment before it).
- New tables clearing_deposit and clearing_deposit_settlement (empty): a
  deposit confirmed by what reached the bank, and the settlements it carries.
Downgrade drops all of it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261124_bnpl_plans'
down_revision = '20261123_piece_return_tag'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'payment_method_plan',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('payment_method_id', sa.Integer(),
                  sa.ForeignKey('payment_method.id', ondelete='CASCADE'), nullable=False),
        sa.Column('installments', sa.Integer(), nullable=False),
        sa.Column('commission_rate', sa.Float(), nullable=False),
        sa.UniqueConstraint('payment_method_id', 'installments', name='uq_payment_method_plan'),
        sa.CheckConstraint('installments > 0', name='ck_payment_method_plan_installments'),
        sa.CheckConstraint('commission_rate >= 0', name='ck_payment_method_plan_rate'),
    )
    op.create_index('ix_payment_method_plan_payment_method_id', 'payment_method_plan', ['payment_method_id'])

    with op.batch_alter_table('payment_method') as batch:
        batch.add_column(sa.Column('deposit_fixed_fee', sa.Float(), nullable=False, server_default='0'))
        batch.add_column(sa.Column('commission_per_order', sa.Boolean(), nullable=False,
                                   server_default=sa.false()))
        batch.add_column(sa.Column('deposit_confirmation_required', sa.Boolean(), nullable=False,
                                   server_default=sa.false()))
        batch.add_column(sa.Column('deposit_difference_allowed', sa.Float(), nullable=False,
                                   server_default='10'))
        batch.add_column(sa.Column('commission_rounding', sa.String(16), nullable=False,
                                   server_default='half_up'))
        batch.add_column(sa.Column('commission_refundable_rate', sa.Float(), nullable=False,
                                   server_default='0'))
    with op.batch_alter_table('invoice_payment') as batch:
        batch.add_column(sa.Column('installments', sa.Integer(), nullable=True))

    op.create_table(
        'clearing_deposit',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('payment_method_id', sa.Integer(),
                  sa.ForeignKey('payment_method.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('deposit_date', sa.Date(), nullable=False),
        sa.Column('amount_received', sa.Float(), nullable=False),
        sa.Column('expected_net', sa.Float(), nullable=False),
        sa.Column('difference', sa.Float(), nullable=False),
        sa.Column('fee_difference', sa.Float(), nullable=False, server_default='0'),
        sa.Column('vat_difference', sa.Float(), nullable=False, server_default='0'),
        sa.Column('voucher_id', sa.Integer(), sa.ForeignKey('voucher.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('bank_reference', sa.String(120), nullable=True),
        sa.Column('note', sa.Text(), nullable=True),
        sa.Column('created_by', sa.String(100), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
    )
    op.create_index('ix_clearing_deposit_payment_method_id', 'clearing_deposit', ['payment_method_id'])
    op.create_table(
        'clearing_deposit_settlement',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('deposit_id', sa.Integer(), sa.ForeignKey('clearing_deposit.id', ondelete='CASCADE'),
                  nullable=False),
        sa.Column('voucher_id', sa.Integer(), sa.ForeignKey('voucher.id', ondelete='RESTRICT'), nullable=False),
        sa.UniqueConstraint('voucher_id', name='uq_clearing_deposit_settlement_voucher'),
    )
    op.create_index('ix_clearing_deposit_settlement_deposit_id', 'clearing_deposit_settlement', ['deposit_id'])


def downgrade():
    op.drop_index('ix_clearing_deposit_settlement_deposit_id', table_name='clearing_deposit_settlement')
    op.drop_table('clearing_deposit_settlement')
    op.drop_index('ix_clearing_deposit_payment_method_id', table_name='clearing_deposit')
    op.drop_table('clearing_deposit')
    with op.batch_alter_table('invoice_payment') as batch:
        batch.drop_column('installments')
    with op.batch_alter_table('payment_method') as batch:
        batch.drop_column('commission_refundable_rate')
        batch.drop_column('commission_rounding')
        batch.drop_column('deposit_difference_allowed')
        batch.drop_column('deposit_confirmation_required')
        batch.drop_column('commission_per_order')
        batch.drop_column('deposit_fixed_fee')
    op.drop_index('ix_payment_method_plan_payment_method_id', table_name='payment_method_plan')
    op.drop_table('payment_method_plan')
