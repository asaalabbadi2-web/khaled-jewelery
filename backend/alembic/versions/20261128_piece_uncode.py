"""A piece's coding undone (the owner, 28 Nov 2026: «ابدأ»).

item.uncoded_at / uncoded_by / uncode_reason: a held piece of a stock batch whose coding was undone
by the manager, with a reason -- its grams back to its category under no number, its chip stopped,
its number kept in the record and never used again (ADR-087 amendment of 28 Nov).

Impact: additive; empty on every row; nothing rewritten. Downgrade drops the three columns: the
pieces undone would read as pieces again with no grams -- so it refuses while one is undone.

Revision ID: 20261128_piece_uncode
Revises: 20261127_open_coding
"""
import sqlalchemy as sa
from alembic import op

revision = '20261128_piece_uncode'
down_revision = '20261127_open_coding'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('item', sa.Column('uncoded_at', sa.DateTime(), nullable=True))
    op.add_column('item', sa.Column('uncoded_by', sa.String(100), nullable=True))
    op.add_column('item', sa.Column('uncode_reason', sa.String(200), nullable=True))


def downgrade():
    undone = op.get_bind().execute(sa.text('SELECT COUNT(*) FROM item WHERE uncoded_at IS NOT NULL')).scalar()
    if undone:
        raise RuntimeError(f'{undone} piece(s) uncoded: dropping the columns would read them as pieces again')
    op.drop_column('item', 'uncode_reason')
    op.drop_column('item', 'uncoded_by')
    op.drop_column('item', 'uncoded_at')
