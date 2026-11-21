"""piece_scan's scope: one section or one category (ADR-085 ت2).

Revision ID: 20261121_piece_scan_scope
Revises: 20261121_item_sections

Impact: two NULL columns on piece_scan -- a scan of one section, or one
category, or (both NULL) every piece in its location, as every scan before
-- and a check that a scan has one scope at most. No row's meaning changes.
Downgrade drops the check and the columns.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261121_piece_scan_scope'
down_revision = '20261121_item_sections'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('piece_scan', sa.Column('section_id', sa.Integer(), nullable=True))
    op.add_column('piece_scan', sa.Column('category_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_piece_scan_section_id', 'piece_scan', 'item_section', ['section_id'], ['id'],
                          ondelete='RESTRICT')
    op.create_foreign_key('fk_piece_scan_category_id', 'piece_scan', 'category', ['category_id'], ['id'],
                          ondelete='RESTRICT')
    op.create_check_constraint('ck_piece_scan_one_scope', 'piece_scan', 'section_id IS NULL OR category_id IS NULL')


def downgrade():
    op.drop_constraint('ck_piece_scan_one_scope', 'piece_scan', type_='check')
    op.drop_constraint('fk_piece_scan_category_id', 'piece_scan', type_='foreignkey')
    op.drop_constraint('fk_piece_scan_section_id', 'piece_scan', type_='foreignkey')
    op.drop_column('piece_scan', 'category_id')
    op.drop_column('piece_scan', 'section_id')
