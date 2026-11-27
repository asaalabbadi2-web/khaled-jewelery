"""A batch of stock coded piece by piece with no weight declared (the owner, 27 Nov 2026: «اعتمده»).

stock_coding.weight may be empty: a batch opened with no weight grows with its pieces, taking the
place's unclassified grams of its karat (ADR-087 amendment of 27 Nov). stock_coding.settled_grams:
what its opening brought from the unclassified to its category -- the category's sales since the
allocation began -- written on it. ended_at / ended_by: the batch ended at the station; it then
takes no piece.

Impact: additive and relaxing. The batches already open keep their weight and their law; no row
is rewritten; the new columns are empty on them. Downgrade refuses while a batch has no weight --
dropping its NOT NULL back would fail on it -- rather than deleting anything.

Revision ID: 20261127_open_coding
Revises: 20261127_piece_label_code
"""
import sqlalchemy as sa
from alembic import op

revision = '20261127_open_coding'
down_revision = '20261127_piece_label_code'
branch_labels = None
depends_on = None


def upgrade():
    op.alter_column('stock_coding', 'weight', existing_type=sa.Float(), nullable=True)
    op.add_column('stock_coding', sa.Column('settled_grams', sa.Float(), nullable=True))
    op.add_column('stock_coding', sa.Column('ended_at', sa.DateTime(), nullable=True))
    op.add_column('stock_coding', sa.Column('ended_by', sa.String(100), nullable=True))


def downgrade():
    bind = op.get_bind()
    open_batches = bind.execute(sa.text('SELECT COUNT(*) FROM stock_coding WHERE weight IS NULL')).scalar()
    if open_batches:
        raise RuntimeError(f'{open_batches} batch(es) with no weight: the downgrade would fail on them -- '
                           'nothing is deleted; end and weigh them by hand first')
    op.drop_column('stock_coding', 'ended_by')
    op.drop_column('stock_coding', 'ended_at')
    op.drop_column('stock_coding', 'settled_grams')
    op.alter_column('stock_coding', 'weight', existing_type=sa.Float(), nullable=False)
