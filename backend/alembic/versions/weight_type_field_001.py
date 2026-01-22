"""Add weight_type field to JournalEntryLine

Revision ID: weight_type_field_001
Revises: dual_system_001
Create Date: 2025-12-14 18:30:00

"""
from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision = 'weight_type_field_001'
down_revision = 'dual_system_001'
branch_labels = None
depends_on = None


def upgrade():
    # Add weight_type column to journal_entry_line table
    op.add_column('journal_entry_line', 
        sa.Column('weight_type', sa.String(20), nullable=True, server_default='ANALYTICAL')
    )
    
    # Update existing rows based on account type
    # Inventory accounts (13xx) → PHYSICAL
    # All others → ANALYTICAL
    connection = op.get_bind()
    connection.execute(
        sa.text("""
            UPDATE journal_entry_line
            SET weight_type = CASE
                WHEN account_id IN (
                    SELECT id FROM account 
                    WHERE account_number LIKE '13%'
                )
                THEN 'PHYSICAL'
                ELSE 'ANALYTICAL'
            END
        """)
    )


def downgrade():
    # Remove weight_type column
    op.drop_column('journal_entry_line', 'weight_type')
