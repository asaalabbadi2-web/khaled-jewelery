"""add soft delete to journal entries

Revision ID: add_soft_delete_je
Revises: 
Create Date: 2025-10-10

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'add_soft_delete_je'
down_revision = '3550da8f556f'
branch_labels = None
depends_on = None


def upgrade():
    # إضافة حقول الحذف الناعم لجدول journal_entry
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.add_column(sa.Column('is_deleted', sa.Boolean(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('deleted_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('deleted_by', sa.String(length=100), nullable=True))
        batch_op.add_column(sa.Column('deletion_reason', sa.String(length=500), nullable=True))
        batch_op.add_column(sa.Column('restored_at', sa.DateTime(), nullable=True))
        batch_op.add_column(sa.Column('restored_by', sa.String(length=100), nullable=True))
        batch_op.create_index('ix_journal_entry_is_deleted', ['is_deleted'], unique=False)

    # إضافة حقول الحذف الناعم لجدول journal_entry_line
    with op.batch_alter_table('journal_entry_line', schema=None) as batch_op:
        batch_op.add_column(sa.Column('is_deleted', sa.Boolean(), nullable=False, server_default='0'))
        batch_op.add_column(sa.Column('deleted_at', sa.DateTime(), nullable=True))


def downgrade():
    # حذف الحقول من journal_entry_line
    with op.batch_alter_table('journal_entry_line', schema=None) as batch_op:
        batch_op.drop_column('deleted_at')
        batch_op.drop_column('is_deleted')

    # حذف الحقول من journal_entry
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.drop_index('ix_journal_entry_is_deleted')
        batch_op.drop_column('restored_by')
        batch_op.drop_column('restored_at')
        batch_op.drop_column('deletion_reason')
        batch_op.drop_column('deleted_by')
        batch_op.drop_column('deleted_at')
        batch_op.drop_column('is_deleted')
