"""buy_price_ratio: the buy price is the market price times a ratio the settings hold (PRICE-BUY-1)

SCHEMA, additive. The owner, 14 Oct 2026: «يجب ان يكون ديناميكي من الاعدادات
ويقرأ من الخادم». The 0.98 written twice in the app (the home price card's buy
price, the scrap purchase screen's fallback) becomes settings.buy_price_ratio,
default 0.98 -- nothing changes until the owner changes it.

Impact: one column on settings with a server default; no row rewritten.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261014_buy_price_ratio'
down_revision = '20261014_bangle_item_category'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('buy_price_ratio', sa.Float(), nullable=False, server_default='0.98'))


def downgrade():
    op.drop_column('settings', 'buy_price_ratio')
