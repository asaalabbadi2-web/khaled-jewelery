"""piece models: a model its pieces share, the sizes it comes in, a piece's model (ADR-093 M1)

Impact: two new tables, piece_model and piece_model_size, empty -- the owner
enters the models; item.model_id, nullable, empty. A model's photo is not
kept here as text: photo_id and thumbnail_id point at the attachments' store
(ADR-094) -- amended 18 Nov 2026 before this migration ever ran on production. Nothing existing read or
changed. Downgrade drops them.

Revision ID: 20261117_piece_models
Revises: 20261117_size_systems
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = '20261117_piece_models'
down_revision = '20261117_size_systems'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'piece_model',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('category_id', sa.Integer(), sa.ForeignKey('category.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('name', sa.String(100), nullable=False),
        sa.Column('supplier_code', sa.String(60), nullable=True),
        sa.Column('expected_wage_per_gram', sa.Numeric(10, 2), nullable=True),
        sa.Column('has_stones', sa.Boolean(), nullable=False, server_default=sa.false()),
        # its photo and thumbnail in the attachments' store (ADR-094; their
        # foreign keys with that table, 20261117_attachments)
        sa.Column('photo_id', sa.Integer(), nullable=True),
        sa.Column('thumbnail_id', sa.Integer(), nullable=True),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('created_by', sa.String(100), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.UniqueConstraint('category_id', 'name', name='uq_piece_model_category_name'),
    )
    op.create_index('ix_piece_model_category_id', 'piece_model', ['category_id'])
    op.create_table(
        'piece_model_size',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('model_id', sa.Integer(), sa.ForeignKey('piece_model.id', ondelete='CASCADE'), nullable=False),
        sa.Column('size_id', sa.Integer(), sa.ForeignKey('size_system_size.id', ondelete='RESTRICT'),
                  nullable=False),
        sa.UniqueConstraint('model_id', 'size_id', name='uq_piece_model_size'),
    )
    op.create_index('ix_piece_model_size_model_id', 'piece_model_size', ['model_id'])
    op.create_index('ix_piece_model_size_size_id', 'piece_model_size', ['size_id'])
    op.add_column('item', sa.Column('model_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_item_model', 'item', 'piece_model', ['model_id'], ['id'], ondelete='RESTRICT')
    op.create_index('ix_item_model_id', 'item', ['model_id'])


def downgrade():
    op.drop_index('ix_item_model_id', table_name='item')
    op.drop_constraint('fk_item_model', 'item', type_='foreignkey')
    op.drop_column('item', 'model_id')
    op.drop_index('ix_piece_model_size_size_id', table_name='piece_model_size')
    op.drop_index('ix_piece_model_size_model_id', table_name='piece_model_size')
    op.drop_table('piece_model_size')
    op.drop_index('ix_piece_model_category_id', table_name='piece_model')
    op.drop_table('piece_model')
