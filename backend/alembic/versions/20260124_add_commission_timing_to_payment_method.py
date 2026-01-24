"""add commission timing to payment_method

Revision ID: 20260124_add_commission_timing_to_payment_method
Revises: 20260122_add_karat_to_category
Create Date: 2026-01-24

"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '20260124_add_commission_timing_to_payment_method'
down_revision = '20260122_add_karat_to_category'
branch_labels = None
depends_on = None


def upgrade():
    # invoice: commission is recorded at invoice time (default)
    # settlement: commission is recorded during clearing/bank settlement
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.add_column(
            sa.Column(
                'commission_timing',
                sa.String(length=20),
                nullable=False,
                server_default='invoice',
            )
        )


def downgrade():
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.drop_column('commission_timing')
