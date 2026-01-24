"""add auto settlement settings to payment_method

Revision ID: 20260124_add_auto_settlement_to_payment_method
Revises: 20260124_add_commission_timing_to_payment_method
Create Date: 2026-01-24

"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '20260124_add_auto_settlement_to_payment_method'
down_revision = '20260124_add_commission_timing_to_payment_method'
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.add_column(
            sa.Column(
                'auto_settlement_enabled',
                sa.Boolean(),
                nullable=False,
                server_default=sa.text('false'),
            )
        )
        # days: settle after N days (uses existing settlement_days)
        # weekday: settle on a specific weekday (0=Mon .. 6=Sun)
        batch_op.add_column(
            sa.Column(
                'settlement_schedule_type',
                sa.String(length=20),
                nullable=False,
                server_default='days',
            )
        )
        batch_op.add_column(sa.Column('settlement_weekday', sa.Integer(), nullable=True))
        batch_op.add_column(
            sa.Column(
                'settlement_bank_safe_box_id',
                sa.Integer(),
                sa.ForeignKey('safe_box.id', ondelete='RESTRICT'),
                nullable=True,
            )
        )


def downgrade():
    with op.batch_alter_table('payment_method') as batch_op:
        batch_op.drop_column('settlement_bank_safe_box_id')
        batch_op.drop_column('settlement_weekday')
        batch_op.drop_column('settlement_schedule_type')
        batch_op.drop_column('auto_settlement_enabled')
