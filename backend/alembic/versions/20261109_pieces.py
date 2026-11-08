"""pieces: a category's tracking, a piece's receipt line, its number sequence (ADR-087 R3.1).

Revision ID: 20261109_pieces
Revises: 20261109_receiving_tolerance

Impact: category.tracking ('weight' for every category, as today); item.receipt_item_id,
created_at, created_by (nullable, empty: no row is a piece yet); the sequence
piece_number_seq for «KJ-» numbers. Nothing existing read or changed.
Downgrade drops them.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261109_pieces'
down_revision = '20261109_receiving_tolerance'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('category', sa.Column('tracking', sa.String(10), nullable=False, server_default='weight'))
    op.add_column('item', sa.Column('receipt_item_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_item_receipt_item', 'item', 'invoice_item', ['receipt_item_id'], ['id'])
    op.create_index('ix_item_receipt_item_id', 'item', ['receipt_item_id'])
    op.add_column('item', sa.Column('created_at', sa.DateTime(), nullable=True))
    op.add_column('item', sa.Column('created_by', sa.String(100), nullable=True))
    op.execute('CREATE SEQUENCE IF NOT EXISTS piece_number_seq START 1')


def downgrade():
    op.execute('DROP SEQUENCE IF EXISTS piece_number_seq')
    op.drop_column('item', 'created_by')
    op.drop_column('item', 'created_at')
    op.drop_index('ix_item_receipt_item_id', table_name='item')
    op.drop_constraint('fk_item_receipt_item', 'item', type_='foreignkey')
    op.drop_column('item', 'receipt_item_id')
    op.drop_column('category', 'tracking')
