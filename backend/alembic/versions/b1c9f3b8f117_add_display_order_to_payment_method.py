"""add_display_order_to_payment_method

Revision ID: b1c9f3b8f117
Revises: d11017b18248
Create Date: 2025-10-16 09:13:30.959764

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b1c9f3b8f117'
down_revision: Union[str, Sequence[str], None] = 'd11017b18248'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # إضافة حقل display_order إلى جدول payment_method
    op.add_column('payment_method', sa.Column('display_order', sa.Integer(), nullable=True, server_default='999'))


def downgrade() -> None:
    """Downgrade schema."""
    # حذف حقل display_order من جدول payment_method
    op.drop_column('payment_method', 'display_order')
