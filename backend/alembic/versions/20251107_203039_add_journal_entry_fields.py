"""add journal entry type and reference fields

Revision ID: 20251107_203039
Revises: 
Create Date: 2025-11-07 20:30:39

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '20251107_203039'
down_revision = None  # Update this if you have previous migrations
branch_labels = None
depends_on = None


def upgrade():
    # Add new columns to journal_entry table
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.add_column(sa.Column('entry_type', sa.String(length=50), nullable=False, server_default='عادي'))
        batch_op.add_column(sa.Column('reference_number', sa.String(length=100), nullable=True))
    
    # Remove server_default after adding the column (optional, for cleaner schema)
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.alter_column('entry_type', server_default=None)


def downgrade():
    # Remove the columns if we need to rollback
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.drop_column('reference_number')
        batch_op.drop_column('entry_type')
