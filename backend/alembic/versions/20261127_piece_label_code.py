"""The code a piece's label prints its number in (the owner, 27 Nov 2026).

settings.piece_label_code -- 'datamatrix' (the label's code since 20 Nov),
'qr', 'aztec' or 'code128'; read at each print (services/piece_label.py,
ADR-097 amendment of 27 Nov). Its default is what is printed today: no label
printed changes, and no row is rewritten but by the column's default.

Revision ID: 20261127_piece_label_code
Revises: 20261126_permission_change
"""
import sqlalchemy as sa
from alembic import op

revision = '20261127_piece_label_code'
down_revision = '20261126_permission_change'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('piece_label_code', sa.String(16), nullable=False,
                                        server_default='datamatrix'))


def downgrade():
    op.drop_column('settings', 'piece_label_code')
