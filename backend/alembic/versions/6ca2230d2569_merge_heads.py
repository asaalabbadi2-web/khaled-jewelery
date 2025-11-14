"""merge_heads

Revision ID: 6ca2230d2569
Revises: 20251107_add_recurring, 20251107_add_recurring_only, 20251111_audit_log
Create Date: 2025-11-11 01:29:05.280525

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '6ca2230d2569'
down_revision: Union[str, Sequence[str], None] = ('20251107_add_recurring', '20251107_add_recurring_only', '20251111_audit_log')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
