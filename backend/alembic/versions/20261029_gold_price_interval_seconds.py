"""gold_price_interval_seconds: the gold price is fetched every N seconds (PRICE-LIVE-1)

SCHEMA, additive, with the owner's choice. The owner, 29 Oct 2026: the
shortest refresh that costs the app nothing -- 15 seconds («ابدأ»). The
interval was in minutes, a minute at the least; it is now in seconds, and the
minutes column stays unread until no deployed screen writes it (a screen that
sends minutes is converted to seconds by the settings route).

Impact: one column with a server default; the settings' row set to 15.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261029_gold_price_interval_seconds'
down_revision = '20261029_points_deficits_from'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('gold_price_auto_update_interval_seconds', sa.Integer(),
                                        nullable=False, server_default='60'))
    op.execute('UPDATE settings SET gold_price_auto_update_interval_seconds = 15')


def downgrade():
    op.drop_column('settings', 'gold_price_auto_update_interval_seconds')
