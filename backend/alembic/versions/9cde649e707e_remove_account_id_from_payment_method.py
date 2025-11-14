"""remove_account_id_from_payment_method

Revision ID: 9cde649e707e
Revises: 8951696d497e
Create Date: 2025-10-31 23:52:02.466969

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '9cde649e707e'
down_revision: Union[str, Sequence[str], None] = '8951696d497e'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Remove account_id column from payment_method table."""
    # SQLite لا يدعم drop constraint مباشرة، نحذف العمود فقط
    with op.batch_alter_table('payment_method', schema=None) as batch_op:
        batch_op.drop_column('account_id')


def downgrade() -> None:
    """Re-add account_id column to payment_method table."""
    with op.batch_alter_table('payment_method', schema=None) as batch_op:
        batch_op.add_column(sa.Column('account_id', sa.INTEGER(), nullable=True))
