"""add_commission_vat_to_invoice_payment

Revision ID: 9f07663d5449
Revises: 926e363cdfba
Create Date: 2025-10-14 14:46:53.267416

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '9f07663d5449'
down_revision: Union[str, Sequence[str], None] = 'c8d39e47e13c'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # إضافة عمود commission_vat إلى جدول invoice_payment
    op.add_column('invoice_payment', sa.Column('commission_vat', sa.Float(), nullable=True, server_default='0.0'))


def downgrade() -> None:
    """Downgrade schema."""
    # حذف عمود commission_vat من جدول invoice_payment
    op.drop_column('invoice_payment', 'commission_vat')
