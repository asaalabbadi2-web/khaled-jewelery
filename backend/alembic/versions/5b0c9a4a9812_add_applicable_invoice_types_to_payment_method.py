"""add applicable invoice types to payment method

Revision ID: 5b0c9a4a9812
Revises: b1c9f3b8f117
Create Date: 2025-10-18 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import json


# revision identifiers, used by Alembic.
revision: str = '5b0c9a4a9812'
down_revision: Union[str, Sequence[str], None] = 'b1c9f3b8f117'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

DEFAULT_INVOICE_TYPES = [
    'بيع',
    'شراء من عميل',
    'مرتجع بيع',
    'مرتجع شراء',
    'شراء',
    'مرتجع شراء (مورد)',
]


def upgrade() -> None:
    """Upgrade schema by adding applicable invoice types column."""
    op.add_column('payment_method', sa.Column('applicable_invoice_types', sa.JSON(), nullable=True))

    default_json = json.dumps(DEFAULT_INVOICE_TYPES, ensure_ascii=False)
    op.execute(
        sa.text(
            'UPDATE payment_method SET applicable_invoice_types = :value WHERE applicable_invoice_types IS NULL'
        ).bindparams(value=default_json)
    )


def downgrade() -> None:
    """Downgrade schema by removing applicable invoice types column."""
    op.drop_column('payment_method', 'applicable_invoice_types')
