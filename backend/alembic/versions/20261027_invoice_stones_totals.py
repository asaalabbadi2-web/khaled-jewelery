"""invoice_stones_totals: a supplier purchase keeps its priced stones and their VAT (27 Oct 2026)

SCHEMA, ADDITIVE, with a backfill.

invoice.stones_subtotal  -- the stones priced by the carat, in riyals (ت4).
invoice.stones_tax_total -- their VAT, as the save took it.

The owner (27 Oct 2026, ADR-062): the cash a purchase can be paid is every
cash debt it posts on the supplier -- its priced stones and their VAT among
them. The save posted them and never kept them on the invoice, so
Invoice.cash_obligation could not count them. Frozen (§13): the VAT is the
save's, not today's rate.

BACKFILL (keep_stones_totals): a supplier purchase ('شراء') with priced stone
lines gets their value from its lines (invoice_item.stones_value) and their
VAT from its own frozen taxes -- total_tax less the gold's and the wages'
(the screen's total_tax is the three, and the save keeps it as sent).

IMPACT: two nullable columns. On the 27 Oct copy no supplier purchase carries
priced stones, so the backfill writes no row there; one saved since is kept.
No entry is touched. Downgrade drops them -- the purchases' cash obligation
then counts the stones no more (their entries keep the riyal lines).

Revision ID: 20261027_invoice_stones_totals
Revises: 20261024_race_honour
Create Date: 2026-10-27
"""
from alembic import op
import sqlalchemy as sa

revision = '20261027_invoice_stones_totals'
down_revision = '20261024_race_honour'
branch_labels = None
depends_on = None


def keep_stones_totals(bind) -> int:
    """Fill the two columns of the purchases saved before them. Returns the rows written."""
    result = bind.execute(sa.text("""
        UPDATE invoice AS i
           SET stones_subtotal = s.value,
               stones_tax_total = GREATEST(ROUND(CAST(COALESCE(i.total_tax, 0)
                                                    - COALESCE(i.gold_tax_total, 0)
                                                    - COALESCE(i.wage_tax_total, 0) AS NUMERIC), 2), 0)
          FROM (SELECT invoice_id, SUM(COALESCE(stones_value, 0)) AS value
                  FROM invoice_item
                 WHERE stones_kind = 'priced'
                 GROUP BY invoice_id) AS s
         WHERE i.id = s.invoice_id
           AND i.invoice_type = 'شراء'
           AND i.stones_subtotal IS NULL
    """))
    return int(result.rowcount or 0)


def upgrade():
    op.add_column('invoice', sa.Column('stones_subtotal', sa.Float(), nullable=True))
    op.add_column('invoice', sa.Column('stones_tax_total', sa.Float(), nullable=True))
    keep_stones_totals(op.get_bind())


def downgrade():
    op.drop_column('invoice', 'stones_tax_total')
    op.drop_column('invoice', 'stones_subtotal')
