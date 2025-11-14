"""merge commission_vat with existing heads

Revision ID: 4047ce459b09
Revises: 59f863c27ef7, 9f07663d5449
Create Date: 2025-10-14 14:48:14.533256

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '4047ce459b09'
down_revision: Union[str, Sequence[str], None] = ('59f863c27ef7', '9f07663d5449')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
