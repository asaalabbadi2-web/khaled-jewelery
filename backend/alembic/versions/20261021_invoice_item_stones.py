"""invoice_item_stones: a line's stones counted as gold or priced by the carat (21 Oct 2026)

SCHEMA, ADDITIVE.

invoice_item.stones_kind  -- 'as_gold' (the supplier counts them as gold: they
                             stay in the line's gold) or 'priced' (by the
                             carat: out of the gold, owed in riyals); NULL for
                             every line before, and a line with no stones.
invoice_item.stones_value -- the priced stones' value in riyals (0 otherwise).

The owner (21 Oct 2026, ت4): «بعض الأحجار تُحسب بسعر القيراط وبعضها تُحسب كذهب».

IMPACT: two nullable columns; no existing row, invoice or entry is touched
(no supplier purchase line on the 17 Oct copy carries stones). Downgrade drops
them -- the kind and value of lines recorded since are lost with them (their
entries keep the stones' riyal lines).

Revision ID: 20261021_invoice_item_stones
Revises: 20261020_expense_vat
Create Date: 2026-10-21
"""
from alembic import op
import sqlalchemy as sa

revision = '20261021_invoice_item_stones'
down_revision = '20261020_expense_vat'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('invoice_item', sa.Column('stones_kind', sa.String(10), nullable=True))
    op.add_column('invoice_item', sa.Column('stones_value', sa.Float(), nullable=True))


def downgrade():
    op.drop_column('invoice_item', 'stones_value')
    op.drop_column('invoice_item', 'stones_kind')
