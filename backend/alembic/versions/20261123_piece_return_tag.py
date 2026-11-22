"""A piece brought back by a sale return: its label as the return found it (ADR-097).

Revision ID: 20261123_piece_return_tag
Revises: 20261123_piece_split

Impact: one new table, piece_return_tag -- a row a piece of a sale return
saved from this release on: its tag read, its printed number typed, or its
label missing. No row before it changes meaning. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261123_piece_return_tag'
down_revision = '20261123_piece_split'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'piece_return_tag',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('invoice_id', sa.Integer(), sa.ForeignKey('invoice.id', ondelete='CASCADE'), nullable=False),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('kind', sa.String(10), nullable=False),
        sa.Column('value', sa.String(64), nullable=True),
        sa.Column('tag_id', sa.Integer(), sa.ForeignKey('piece_tag.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=True),
        sa.UniqueConstraint('invoice_id', 'item_id', name='uq_piece_return_tag_piece'),
        sa.CheckConstraint("kind IN ('read', 'printed', 'missing')", name='ck_piece_return_tag_kind'),
    )
    op.create_index('ix_piece_return_tag_invoice_id', 'piece_return_tag', ['invoice_id'])
    op.create_index('ix_piece_return_tag_item_id', 'piece_return_tag', ['item_id'])


def downgrade():
    op.drop_index('ix_piece_return_tag_item_id', table_name='piece_return_tag')
    op.drop_index('ix_piece_return_tag_invoice_id', table_name='piece_return_tag')
    op.drop_table('piece_return_tag')
