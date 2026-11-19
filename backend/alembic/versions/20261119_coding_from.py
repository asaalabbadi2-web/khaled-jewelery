"""coding_from: coding the stock on hand opens on its own day (ADR-087 R3.5; the owner, 19 Nov 2026).

Revision ID: 20261119_coding_from
Revises: 20261117_attachments

Impact: one nullable date on settings, NULL on every row -- coding from stock
stays as it was (with receiving, 2027's first day) until the manager turns it
on in the settings. No row's meaning changes. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261119_coding_from'
down_revision = '20261117_attachments'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('coding_from', sa.Date(), nullable=True))


def downgrade():
    op.drop_column('settings', 'coding_from')
