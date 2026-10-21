"""settings_gold_cost_from: the day the gold is costed at its pool's average (21 Oct 2026)

SCHEMA, ADDITIVE.

settings.gold_cost_from -- from this day a gold purchase paid in riyals is
                           written into its pool's stock (1310 / 1300) instead
                           of purchases (512), and the cost of what is sold is
                           its pool's average (ADR-042 phase 3). NULL: never --
                           2026's books post as they always have. The 2027
                           database is opened with it set to 1 January
                           (ADR-044). A policy: data, not code.

IMPACT: one nullable column, NULL on every existing row: no posting changes
until it is set. Downgrade drops it -- and with it the rule, from the next
document on.

Revision ID: 20261021_settings_gold_cost_from
Revises: 20261021_invoice_item_stones
Create Date: 2026-10-21
"""
from alembic import op
import sqlalchemy as sa

revision = '20261021_settings_gold_cost_from'
down_revision = '20261021_invoice_item_stones'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('gold_cost_from', sa.Date(), nullable=True))


def downgrade():
    op.drop_column('settings', 'gold_cost_from')
