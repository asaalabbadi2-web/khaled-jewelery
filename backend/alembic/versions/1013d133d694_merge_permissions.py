"""merge_permissions

Revision ID: 1013d133d694
Revises: 20251111_permissions, 6ca2230d2569
Create Date: 2025-11-11 01:36:13.053877

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '1013d133d694'
down_revision: Union[str, Sequence[str], None] = ('20251111_permissions', '6ca2230d2569')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
