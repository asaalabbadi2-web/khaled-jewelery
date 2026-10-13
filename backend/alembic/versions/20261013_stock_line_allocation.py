"""stock_line_allocation: a category's share of a stock line (ADR-045 A1)

SCHEMA only.

The stock is the posted entry lines on the accounts of stock safes; an entry
groups a karat into one line, and this table says how much of it was which
category (and, in phase C, which piece). Written by services/stock_ledger
(the one writer, and its law); a line's allocations go with the line -- ON
DELETE CASCADE, so bulk deletes of lines cannot leave one behind.

IMPACT: one new empty table. No entry, balance or existing row changes.
Invoices posted from this release allocate their stock lines; earlier ones
stay unclassified (2026's history is not repaired -- ADR-045). Downgrade drops
the table.

Revision ID: 20261013_stock_line_allocation
Revises: 20261013_stock_location
Create Date: 2026-10-13
"""
from alembic import op
import sqlalchemy as sa

revision = '20261013_stock_line_allocation'
down_revision = '20261013_stock_location'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    if 'stock_line_allocation' in sa.inspect(bind).get_table_names():
        return
    op.create_table(
        'stock_line_allocation',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('journal_entry_line_id', sa.Integer(),
                  sa.ForeignKey('journal_entry_line.id', ondelete='CASCADE'), nullable=False),
        sa.Column('karat', sa.Integer(), nullable=False),
        sa.Column('category_id', sa.Integer(), sa.ForeignKey('category.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('grams', sa.Float(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=True),
    )
    op.create_index('ix_stock_line_allocation_journal_entry_line_id', 'stock_line_allocation',
                    ['journal_entry_line_id'])
    op.create_index('ix_stock_line_allocation_category_id', 'stock_line_allocation', ['category_id'])
    op.create_index('ix_stock_line_allocation_item_id', 'stock_line_allocation', ['item_id'])


def downgrade():
    op.drop_table('stock_line_allocation')
