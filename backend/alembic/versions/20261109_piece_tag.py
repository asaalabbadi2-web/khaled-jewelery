"""piece_tag: a piece's RFID tags, one active at a time, an active value unique (ADR-087 R3.7).

Revision ID: 20261109_piece_tag
Revises: 20261109_stock_coding

Impact: a new table piece_tag (empty) with two partial unique indexes on
the active rows (stopped_at IS NULL): value, and item_id. Nothing existing
read or changed. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261109_piece_tag'
down_revision = '20261109_stock_coding'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'piece_tag',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('value', sa.String(64), nullable=False),
        sa.Column('technology', sa.String(20), nullable=False, server_default='uhf_epc96'),
        sa.Column('mounted_at', sa.DateTime(), nullable=False),
        sa.Column('mounted_by', sa.String(100), nullable=True),
        sa.Column('stopped_at', sa.DateTime(), nullable=True),
        sa.Column('stopped_by', sa.String(100), nullable=True),
        sa.Column('stop_reason', sa.String(200), nullable=True),
    )
    op.create_index('ix_piece_tag_item_id', 'piece_tag', ['item_id'])
    op.create_index('uq_piece_tag_active_value', 'piece_tag', ['value'], unique=True,
                    postgresql_where=sa.text('stopped_at IS NULL'))
    op.create_index('uq_piece_tag_active_item', 'piece_tag', ['item_id'], unique=True,
                    postgresql_where=sa.text('stopped_at IS NULL'))


def downgrade():
    op.drop_index('uq_piece_tag_active_item', table_name='piece_tag')
    op.drop_index('uq_piece_tag_active_value', table_name='piece_tag')
    op.drop_index('ix_piece_tag_item_id', table_name='piece_tag')
    op.drop_table('piece_tag')
