"""merge_migrations

Revision ID: d11017b18248
Revises: 4047ce459b09
Create Date: 2025-10-15 09:56:40.887683

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'd11017b18248'
down_revision: Union[str, Sequence[str], None] = '4047ce459b09'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
