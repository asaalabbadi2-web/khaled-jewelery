"""receiving_tolerance: a receipt line's supplier weight against its weight received (ADR-087 §4).

Revision ID: 20261109_receiving_tolerance
Revises: 20261108_receiving

Impact: one column on settings, 0.10 g (the owner, 8 Nov 2026) -- read only
by a receipt line that says a supplier's weight, which no screen sends before
receiving works. No row's meaning changes. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261109_receiving_tolerance'
down_revision = '20261108_receiving'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('receiving_weight_tolerance', sa.Float(), nullable=False,
                                        server_default=sa.text('0.10')))


def downgrade():
    op.drop_column('settings', 'receiving_weight_tolerance')
