"""vat_return: a filed VAT return -- a period's output and input VAT closed into what is owed (ADR-043, phase 6)

ADDITIVE.

Creates vat_return (period_start, period_end, output_vat, input_vat, net,
journal_entry_id, filed_by, filed_at). The filing entry and the account 2301
«صافي ضريبة القيمة المضافة المستحقة للهيئة» are written by
services/vat_return.py when a return is filed -- none by this migration.

Idempotent: the table only when absent.

IMPACT: none on existing data. Downgrade drops the table.

Revision ID: 20261011_vat_return
Revises: 20261011_vat_policy_period
Create Date: 2026-10-11
"""
from alembic import op
import sqlalchemy as sa

revision = '20261011_vat_return'
down_revision = '20261011_vat_policy_period'
branch_labels = None
depends_on = None


def upgrade():
    if 'vat_return' in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        'vat_return',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('period_start', sa.Date(), nullable=False),
        sa.Column('period_end', sa.Date(), nullable=False),
        sa.Column('output_vat', sa.Float(), nullable=False, server_default='0'),
        sa.Column('input_vat', sa.Float(), nullable=False, server_default='0'),
        sa.Column('net', sa.Float(), nullable=False, server_default='0'),
        sa.Column('journal_entry_id', sa.Integer(), sa.ForeignKey('journal_entry.id'), nullable=True),
        sa.Column('filed_by', sa.String(100), nullable=True),
        sa.Column('filed_at', sa.DateTime(), nullable=True),
    )
    op.create_index('ix_vat_return_period_start', 'vat_return', ['period_start'])
    op.create_index('ix_vat_return_period_end', 'vat_return', ['period_end'])


def downgrade():
    if 'vat_return' in sa.inspect(op.get_bind()).get_table_names():
        op.drop_index('ix_vat_return_period_end', table_name='vat_return')
        op.drop_index('ix_vat_return_period_start', table_name='vat_return')
        op.drop_table('vat_return')
