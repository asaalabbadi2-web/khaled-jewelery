"""add karat column to category

Revision ID: 20260122_add_karat_to_category
Revises: 20251128_office_supplier_link, 20251227_allow_partial_invoice_payments, weight_type_field_001
Create Date: 2026-01-22

"""

from __future__ import annotations

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect


# revision identifiers, used by Alembic.
revision: str = '20260122_add_karat_to_category'
down_revision: Union[str, Sequence[str], None] = (
    '20251128_office_supplier_link',
    '20251227_allow_partial_invoice_payments',
    'weight_type_field_001',
)
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    inspector = inspect(bind)

    tables = set(inspector.get_table_names())
    if 'category' not in tables:
        # Nothing to do (fresh installs should create it via earlier migration).
        return

    columns = {col['name'] for col in inspector.get_columns('category')}
    if 'karat' in columns:
        return

    with op.batch_alter_table('category', schema=None) as batch_op:
        batch_op.add_column(sa.Column('karat', sa.String(length=10), nullable=True))


def downgrade() -> None:
    bind = op.get_bind()
    inspector = inspect(bind)

    tables = set(inspector.get_table_names())
    if 'category' not in tables:
        return

    columns = {col['name'] for col in inspector.get_columns('category')}
    if 'karat' not in columns:
        return

    with op.batch_alter_table('category', schema=None) as batch_op:
        batch_op.drop_column('karat')
