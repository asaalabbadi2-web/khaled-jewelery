"""item.request_key: a piece registered once under its save attempt's key (ADR-087 R3.4).

Revision ID: 20261109_piece_request_key
Revises: 20261109_pieces

Impact: item.request_key, nullable, unique (NULLs not compared): every row
today NULL. Nothing existing read or changed. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261109_piece_request_key'
down_revision = '20261109_pieces'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('item', sa.Column('request_key', sa.String(64), nullable=True))
    op.create_unique_constraint('uq_item_request_key', 'item', ['request_key'])


def downgrade():
    op.drop_constraint('uq_item_request_key', 'item', type_='unique')
    op.drop_column('item', 'request_key')
