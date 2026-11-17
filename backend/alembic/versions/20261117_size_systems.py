"""size systems: the sizes the categories share, a category's system, a piece's size (ADR-093 M0)

Impact: two new tables, size_system and size_system_size, empty -- the owner
enters the shop's systems; category.size_system_id and item.size_id,
nullable, empty. Nothing existing read or changed. Downgrade drops them.

Revision ID: 20261117_size_systems
Revises: 20261117_gram_profit_zakat_excluded
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = '20261117_size_systems'
down_revision = '20261117_gram_profit_zakat_excluded'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'size_system',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('name', sa.String(60), nullable=False, unique=True),
        sa.Column('measurement_label', sa.String(60), nullable=True),
        sa.Column('created_by', sa.String(100), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
    )
    op.create_table(
        'size_system_size',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('system_id', sa.Integer(), sa.ForeignKey('size_system.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('label', sa.String(20), nullable=False),
        sa.Column('position', sa.Integer(), nullable=False),
        sa.Column('measurement', sa.Numeric(8, 2), nullable=True),
        sa.Column('created_by', sa.String(100), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('system_id', 'label', name='uq_size_system_size_label'),
    )
    op.create_index('ix_size_system_size_system_id', 'size_system_size', ['system_id'])
    op.add_column('category', sa.Column('size_system_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_category_size_system', 'category', 'size_system', ['size_system_id'], ['id'],
                          ondelete='RESTRICT')
    op.create_index('ix_category_size_system_id', 'category', ['size_system_id'])
    op.add_column('item', sa.Column('size_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_item_size', 'item', 'size_system_size', ['size_id'], ['id'], ondelete='RESTRICT')
    op.create_index('ix_item_size_id', 'item', ['size_id'])


def downgrade():
    op.drop_index('ix_item_size_id', table_name='item')
    op.drop_constraint('fk_item_size', 'item', type_='foreignkey')
    op.drop_column('item', 'size_id')
    op.drop_index('ix_category_size_system_id', table_name='category')
    op.drop_constraint('fk_category_size_system', 'category', type_='foreignkey')
    op.drop_column('category', 'size_system_id')
    op.drop_index('ix_size_system_size_system_id', table_name='size_system_size')
    op.drop_table('size_system_size')
    op.drop_table('size_system')
