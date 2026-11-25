"""«إقفال الباقي»: a receipt line's or a batch's uncoded rest closed onto the shortage.

Revision ID: 20261125_coding_rest
Revises: 20261124_bnpl_plans

Impact: one new table, coding_rest_close (one row a line or batch closed --
its grams above zero a rest onto the shortage, below an excess from the surplus),
and one settings column, coding_rest_tolerance (0.05 -- the owner, 25 Nov
2026). No row before it changes meaning: no rest has been closed. Downgrade
drops both.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261125_coding_rest'
down_revision = '20261124_bnpl_plans'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'coding_rest_close',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('receipt_item_id', sa.Integer(), sa.ForeignKey('invoice_item.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('coding_id', sa.Integer(), sa.ForeignKey('stock_coding.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('grams', sa.Float(), nullable=False),
        sa.Column('journal_entry_id', sa.Integer(), sa.ForeignKey('journal_entry.id', ondelete='RESTRICT'),
                  nullable=False),
        sa.Column('reason', sa.String(200), nullable=False),
        sa.Column('closed_by', sa.String(100), nullable=False),
        sa.Column('closed_at', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('receipt_item_id', name='uq_coding_rest_close_line'),
        sa.UniqueConstraint('coding_id', name='uq_coding_rest_close_batch'),
        sa.CheckConstraint('(receipt_item_id IS NULL) <> (coding_id IS NULL)', name='ck_coding_rest_close_one_source'),
        sa.CheckConstraint('grams <> 0', name='ck_coding_rest_close_grams'),
    )
    op.add_column('settings', sa.Column('coding_rest_tolerance', sa.Float(), nullable=False, server_default='0.05'))


def downgrade():
    op.drop_column('settings', 'coding_rest_tolerance')
    op.drop_table('coding_rest_close')
