"""add fixed commission amount to payment_method

Revision ID: 20260125_add_fixed_commission_to_payment_method
Revises: 20260124_add_auto_settlement_to_payment_method
Create Date: 2026-01-25

"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '20260125_add_fixed_commission_to_payment_method'
down_revision = '20260124_add_auto_settlement_to_payment_method'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.add_column(
            sa.Column(
                'commission_fixed_amount',
                sa.Float(),
                nullable=False,
                server_default=sa.text('0'),
            )
        )


def downgrade():
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.drop_column('commission_fixed_amount')
