"""add manufacturing wage mode to settings

Revision ID: 4e6c2a3d1f8b
Revises: 9cde649e707e
Create Date: 2025-11-04 10:25:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '4e6c2a3d1f8b'
down_revision: Union[str, Sequence[str], None] = '9cde649e707e'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema by adding manufacturing wage mode toggle."""
    op.add_column(
        'settings',
        sa.Column('manufacturing_wage_mode', sa.String(length=20), nullable=True, server_default='expense')
    )
    op.execute("""
        UPDATE settings
        SET manufacturing_wage_mode = 'expense'
        WHERE manufacturing_wage_mode IS NULL
    """)


def downgrade() -> None:
    """Downgrade schema by removing manufacturing wage mode toggle."""
    op.drop_column('settings', 'manufacturing_wage_mode')
