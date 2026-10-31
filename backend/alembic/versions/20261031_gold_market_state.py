"""gold_market_state: whether the world's gold market is open, as its source says (PRICE-MARKET-1)

SCHEMA, additive. The owner, 31 Oct 2026: «سعر الذهب العالمي يغلق في عطلة
نهاية الأسبوع وغيرها، أليس من الأفضل أن يُسجَّل مغلق بدل التحديث التلقائي دون
جدوى؟» -- each weekend saved ~1,300 rows a day at one price, and asked the
source every 15 seconds for it. One row: open or closed, the source's last
quote, the last check -- so the scheduler stops saving and slows while the
market is closed, and the screens say «السوق مغلق».

Impact: one new table, one row written by the price scheduler; skipped when
the boot's create_all made it first. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261031_gold_market_state'
down_revision = '20261029_gold_price_interval_seconds'
branch_labels = None
depends_on = None


def upgrade():
    # Idempotent: db.create_all() at boot may have made it from the model before
    # this migration runs (ADR-023's pattern; it did on the 31 Oct copy).
    if sa.inspect(op.get_bind()).has_table('gold_market_state'):
        return
    op.create_table(
        'gold_market_state',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('is_open', sa.Boolean(), nullable=True),
        sa.Column('last_quote_at', sa.DateTime(), nullable=True),
        sa.Column('checked_at', sa.DateTime(), nullable=True),
        sa.Column('source', sa.String(40), nullable=True),
        sa.Column('unavailable_since', sa.DateTime(), nullable=True),
    )


def downgrade():
    op.drop_table('gold_market_state')
