"""merge_barcode_branch

Revision ID: 59f863c27ef7
Revises: 854a75819ffb, c8d39e47e13c
Create Date: 2025-10-12 00:32:17.473363

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '59f863c27ef7'
down_revision: Union[str, Sequence[str], None] = ('854a75819ffb', 'c8d39e47e13c')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
