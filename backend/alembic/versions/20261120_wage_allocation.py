"""wage_allocation and settings.wage_pools_from: the wages' stock by category and piece (ADR-096 ت1).

Revision ID: 20261120_wage_allocation
Revises: 20261119_piece_coded_wage

Impact: a new empty table, and one nullable date on settings, NULL on every
row -- nothing is allocated and nothing is refused until the transition
writes 2027's first day into 2027's books (the owner, 19 Nov 2026). No row's
meaning changes in 2026's books. Downgrade drops both.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261120_wage_allocation'
down_revision = '20261119_piece_coded_wage'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('wage_pools_from', sa.Date(), nullable=True))
    op.create_table(
        'wage_allocation',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('journal_entry_line_id', sa.Integer(),
                  sa.ForeignKey('journal_entry_line.id', ondelete='CASCADE'), nullable=False),
        sa.Column('karat', sa.Integer(), nullable=False),
        sa.Column('category_id', sa.Integer(), sa.ForeignKey('category.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('riyals', sa.Float(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=True),
    )
    op.create_index('ix_wage_allocation_journal_entry_line_id', 'wage_allocation', ['journal_entry_line_id'])
    op.create_index('ix_wage_allocation_category_id', 'wage_allocation', ['category_id'])
    op.create_index('ix_wage_allocation_item_id', 'wage_allocation', ['item_id'])


def downgrade():
    op.drop_table('wage_allocation')
    op.drop_column('settings', 'wage_pools_from')
