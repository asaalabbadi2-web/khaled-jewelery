"""opening_waiting: the count day's closing price and the riyals waiting, frozen on the opening's approval (ADR-044, TR-3).

Revision ID: 20261107_opening_waiting
Revises: 20261106_opening_figures

Impact: four nullable columns on opening_approval and one on opening_figure,
both added by 20261106 and empty on production. Nothing read or written by
another table; nothing destroyed. Downgrade drops the five columns.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261107_opening_waiting'
down_revision = '20261106_opening_figures'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('opening_approval', sa.Column('count_day', sa.Date(), nullable=True))
    op.add_column('opening_approval', sa.Column('closing_price', sa.Float(), nullable=True))
    op.add_column('opening_approval', sa.Column('waiting_cash', sa.Float(), nullable=True))
    op.add_column('opening_approval', sa.Column('to_gold_cash', sa.Float(), nullable=True))
    op.add_column('opening_figure', sa.Column('gold_grams', sa.Float(), nullable=True))


def downgrade():
    op.drop_column('opening_figure', 'gold_grams')
    for column in ('to_gold_cash', 'waiting_cash', 'closing_price', 'count_day'):
        op.drop_column('opening_approval', column)
