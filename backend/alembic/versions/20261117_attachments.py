"""attachments: a file on the server's disk, its record here (ADR-094)

Impact: one new table, attachment, empty -- the photos of a customer's
scrap purchase were never kept (the screen sent their count only). The files
live in MEDIA_ROOT (the volume media_data:/data/media), not here. Nothing
existing read or changed. Downgrade drops the table; the files stay.

Revision ID: 20261117_attachments
Revises: 20261117_piece_models
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = '20261117_attachments'
down_revision = '20261117_piece_models'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'attachment',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('sha256', sa.String(64), nullable=False),
        sa.Column('kind', sa.String(10), nullable=False),
        sa.Column('bytes', sa.Integer(), nullable=False),
        sa.Column('width', sa.Integer(), nullable=True),
        sa.Column('height', sa.Integer(), nullable=True),
        sa.Column('role', sa.String(40), nullable=False),
        sa.Column('entity_type', sa.String(30), nullable=True),
        sa.Column('entity_id', sa.Integer(), nullable=True),
        sa.Column('uploaded_by', sa.String(100), nullable=False),
        sa.Column('uploaded_at', sa.DateTime(), nullable=False),
        sa.Column('linked_at', sa.DateTime(), nullable=True),
    )
    op.create_index('ix_attachment_sha256', 'attachment', ['sha256'])
    op.create_index('ix_attachment_entity', 'attachment', ['entity_type', 'entity_id'])
    # a piece model's photo and thumbnail are files here (ADR-093 §7)
    op.create_foreign_key('fk_piece_model_photo', 'piece_model', 'attachment', ['photo_id'], ['id'],
                          ondelete='RESTRICT')
    op.create_foreign_key('fk_piece_model_thumbnail', 'piece_model', 'attachment', ['thumbnail_id'], ['id'],
                          ondelete='RESTRICT')


def downgrade():
    op.drop_constraint('fk_piece_model_thumbnail', 'piece_model', type_='foreignkey')
    op.drop_constraint('fk_piece_model_photo', 'piece_model', type_='foreignkey')
    op.drop_index('ix_attachment_entity', table_name='attachment')
    op.drop_index('ix_attachment_sha256', table_name='attachment')
    op.drop_table('attachment')
