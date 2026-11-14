"""period_expense: the cost of a period, its vouchers' lines its payments (ADR-090, phase 3)

A new table, and a nullable link on voucher_account_line: a payment's cash
debit line may name the period expense it pays. Nothing existing changes; no
row is written. The two accounts are made and mapped by
tools/repair/period_expense_accounts.py after deploy.

Revision ID: 20261114_period_expense
Revises: 20261114_period_lock
Create Date: 2026-11-14
"""
import sqlalchemy as sa
from alembic import op

revision = '20261114_period_expense'
down_revision = '20261114_period_lock'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if 'period_expense' not in inspector.get_table_names():
        op.create_table(
            'period_expense',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('description', sa.String(length=300), nullable=False),
            sa.Column('expense_account_id', sa.Integer(), sa.ForeignKey('account.id'), nullable=False, index=True),
            sa.Column('amount', sa.Numeric(14, 2), nullable=False),
            sa.Column('period_start', sa.Date(), nullable=False),
            sa.Column('period_end', sa.Date(), nullable=False),
            sa.Column('status', sa.String(length=20), nullable=False, server_default='active'),
            sa.Column('opened_on', sa.Date(), nullable=True),
            sa.Column('accrued_before_opening', sa.Numeric(14, 2), nullable=False, server_default='0'),
            sa.Column('paid_before_opening', sa.Numeric(14, 2), nullable=False, server_default='0'),
            sa.Column('created_by', sa.String(length=100), nullable=False),
            sa.Column('created_at', sa.DateTime(), nullable=False),
            sa.CheckConstraint('amount > 0', name='ck_period_expense_amount_positive'),
            sa.CheckConstraint('period_end >= period_start', name='ck_period_expense_period'),
        )
    columns = {c['name'] for c in inspector.get_columns('voucher_account_line')}
    if 'period_expense_id' not in columns:
        op.add_column('voucher_account_line', sa.Column('period_expense_id', sa.Integer(), nullable=True))
        op.create_foreign_key('fk_voucher_account_line_period_expense', 'voucher_account_line', 'period_expense',
                              ['period_expense_id'], ['id'])
        op.create_index('ix_voucher_account_line_period_expense_id', 'voucher_account_line', ['period_expense_id'])


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    columns = {c['name'] for c in inspector.get_columns('voucher_account_line')}
    if 'period_expense_id' in columns:
        op.drop_index('ix_voucher_account_line_period_expense_id', table_name='voucher_account_line')
        op.drop_constraint('fk_voucher_account_line_period_expense', 'voucher_account_line', type_='foreignkey')
        op.drop_column('voucher_account_line', 'period_expense_id')
    if 'period_expense' in inspector.get_table_names():
        op.drop_table('period_expense')
