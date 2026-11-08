"""stock_coding: a batch of existing stock coded piece by piece (ADR-087 R3.5).

Revision ID: 20261109_stock_coding
Revises: 20261109_piece_request_key

Impact: a new table stock_coding (empty); item.coding_id (nullable, empty)
with its foreign key and index. Nothing existing read or changed.
Downgrade drops them.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261109_stock_coding'
down_revision = '20261109_piece_request_key'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'stock_coding',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('safe_box_id', sa.Integer(), sa.ForeignKey('safe_box.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('category_id', sa.Integer(), sa.ForeignKey('category.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('karat', sa.Integer(), nullable=False),
        sa.Column('weight', sa.Float(), nullable=False),
        sa.Column('wage_per_gram', sa.Float(), nullable=False),
        sa.Column('note', sa.String(200), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=True),
    )
    op.create_index('ix_stock_coding_safe_box_id', 'stock_coding', ['safe_box_id'])
    op.add_column('item', sa.Column('coding_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_item_stock_coding', 'item', 'stock_coding', ['coding_id'], ['id'])
    op.create_index('ix_item_coding_id', 'item', ['coding_id'])


def downgrade():
    op.drop_index('ix_item_coding_id', table_name='item')
    op.drop_constraint('fk_item_stock_coding', 'item', type_='foreignkey')
    op.drop_column('item', 'coding_id')
    op.drop_index('ix_stock_coding_safe_box_id', table_name='stock_coding')
    op.drop_table('stock_coding')
