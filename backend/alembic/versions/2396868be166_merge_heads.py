"""merge_heads

Revision ID: 2396868be166
Revises: 6b85df6f61db, add_soft_delete_je
Create Date: 2025-10-10 14:43:11.264065

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '2396868be166'
down_revision: Union[str, Sequence[str], None] = ('6b85df6f61db', 'add_soft_delete_je')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
