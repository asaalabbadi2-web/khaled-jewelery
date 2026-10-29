"""points_deficits_from: an invoice's loss comes off its employee's points, from this day (POINTS-DEFICIT-1)

SCHEMA, additive, with its day. The owner, 29 Oct 2026: «العجز في فواتير البيع
والشراء يجب أن يخصم من نقاط الموظف» -- from the day it is deployed. The column
takes that day on the settings' row as it is added (CURRENT_DATE), and no
default after: a database made later sets it itself. An invoice before it
keeps its loss floored at nothing, as it was scored.

Impact: one nullable column on settings; the one row given the day of the upgrade.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261029_points_deficits_from'
down_revision = '20261029_office_price_terms'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('points_deficits_from', sa.Date(), nullable=True))
    op.execute('UPDATE settings SET points_deficits_from = CURRENT_DATE')


def downgrade():
    op.drop_column('settings', 'points_deficits_from')
