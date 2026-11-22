"""A composite piece split into its parts (ADR-099).

Revision ID: 20261123_piece_split
Revises: 20261121_piece_scan_scope

Impact: two new tables (piece_split, piece_split_part), one NULL column on
item (split_part_id: a piece born of a split's part, unique) and one on
settings (piece_split_tolerance, 0.05 -- the owner, 23 Nov 2026). No row
changes meaning: every piece today has a receipt line or a batch. Downgrade
drops them; it is refused by the foreign keys once a split was made.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261123_piece_split'
down_revision = '20261121_piece_scan_scope'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'piece_split',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('piece_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('journal_entry_id', sa.Integer(), sa.ForeignKey('journal_entry.id', ondelete='RESTRICT'),
                  nullable=False),
        sa.Column('reason', sa.String(200), nullable=False),
        sa.Column('difference', sa.Float(), nullable=False, server_default='0'),
        sa.Column('split_by', sa.String(100), nullable=False),
        sa.Column('split_at', sa.DateTime(), nullable=False),
        sa.Column('request_key', sa.String(64), nullable=True),
        sa.UniqueConstraint('piece_id', name='uq_piece_split_piece'),
        sa.UniqueConstraint('request_key', name='uq_piece_split_request_key'),
    )
    op.create_table(
        'piece_split_part',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('split_id', sa.Integer(), sa.ForeignKey('piece_split.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('position', sa.Integer(), nullable=False),
        sa.Column('category_id', sa.Integer(), sa.ForeignKey('category.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('weight', sa.Float(), nullable=False),
        sa.Column('stones_weight', sa.Float(), nullable=False, server_default='0'),
        sa.Column('wage', sa.Float(), nullable=False),
        sa.CheckConstraint('weight > 0', name='ck_piece_split_part_weight'),
        sa.CheckConstraint('stones_weight >= 0 AND stones_weight < weight', name='ck_piece_split_part_stones'),
        sa.CheckConstraint('wage >= 0', name='ck_piece_split_part_wage'),
    )
    op.create_index('ix_piece_split_part_split_id', 'piece_split_part', ['split_id'])
    op.add_column('item', sa.Column('split_part_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_item_piece_split_part', 'item', 'piece_split_part', ['split_part_id'], ['id'],
                          ondelete='RESTRICT')
    op.create_unique_constraint('uq_item_split_part_id', 'item', ['split_part_id'])
    op.add_column('settings', sa.Column('piece_split_tolerance', sa.Float(), nullable=False, server_default='0.05'))


def downgrade():
    op.drop_column('settings', 'piece_split_tolerance')
    op.drop_constraint('uq_item_split_part_id', 'item', type_='unique')
    op.drop_constraint('fk_item_piece_split_part', 'item', type_='foreignkey')
    op.drop_column('item', 'split_part_id')
    op.drop_index('ix_piece_split_part_split_id', table_name='piece_split_part')
    op.drop_table('piece_split_part')
    op.drop_table('piece_split')
