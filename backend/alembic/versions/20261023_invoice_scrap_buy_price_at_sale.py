"""invoice_scrap_buy_price_at_sale: a sale's scrap price, saved when it is recorded (23 Oct 2026)

SCHEMA, ADDITIVE.

invoice.scrap_buy_price_at_sale -- the scrap price per gram of the main karat
                                   when the sale was recorded: the market
                                   times the settings' buy ratio. What waits
                                   to be closed is measured against it (the
                                   owner, ADR-048 decision 5 restated). Frozen:
                                   the ratio is a policy that moves.

IMPACT: one nullable column, NULL on every existing row. A sale from before
reads its saved market price (profit_weight_price_per_gram) times today's
ratio. Downgrade drops it; the engine falls back the same way.

Revision ID: 20261023_invoice_scrap_buy_price_at_sale
Revises: 20261022_invoice_correction
Create Date: 2026-10-23
"""
from alembic import op
import sqlalchemy as sa

revision = '20261023_invoice_scrap_buy_price_at_sale'
down_revision = '20261022_invoice_correction'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('invoice', sa.Column('scrap_buy_price_at_sale', sa.Float(), nullable=True))


def downgrade():
    op.drop_column('invoice', 'scrap_buy_price_at_sale')
