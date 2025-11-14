"""add_barcode_to_items

Revision ID: 854a75819ffb
Revises: c8d39e47e13c
Create Date: 2025-10-12 00:29:37.637788

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '854a75819ffb'
down_revision: Union[str, Sequence[str], None] = '7ff60cdf8f40'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # إضافة حقل barcode إلى جدول item
    op.add_column('item', sa.Column('barcode', sa.String(length=100), nullable=True))
    
    # إنشاء فهرس للبحث السريع
    op.create_index('ix_item_barcode', 'item', ['barcode'], unique=True)


def downgrade() -> None:
    """Downgrade schema."""
    # حذف الفهرس
    op.drop_index('ix_item_barcode', table_name='item')
    
    # حذف العمود
    op.drop_column('item', 'barcode')
