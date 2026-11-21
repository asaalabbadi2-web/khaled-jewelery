"""item_section; a category's section (ADR-093 amendment).

Revision ID: 20261121_item_sections
Revises: 20261121_piece_scans

Impact: one new empty table, and category.section_id NULL on every row -- no
category is in a section until the owner sets it («الأقسام»). A grouping
only: no balance, no posting reads it. Downgrade drops the column and the
table.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261121_item_sections'
down_revision = '20261121_piece_scans'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'item_section',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('name', sa.String(60), nullable=False, unique=True),
        sa.Column('sort_order', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=True),
    )
    op.add_column('category', sa.Column('section_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_category_section_id', 'category', 'item_section', ['section_id'], ['id'],
                          ondelete='RESTRICT')
    op.create_index('ix_category_section_id', 'category', ['section_id'])


def downgrade():
    op.drop_index('ix_category_section_id', table_name='category')
    op.drop_constraint('fk_category_section_id', 'category', type_='foreignkey')
    op.drop_column('category', 'section_id')
    op.drop_table('item_section')
