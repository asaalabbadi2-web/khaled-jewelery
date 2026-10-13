"""stock_location: which gold safes are stock, and of what kind (ADR-045 A0)

SCHEMA + DATA, written once.

The inventory ledger is compared with the books on the accounts of the safes
that are stock -- the showroom, the employees' custody, scrap. An office's gold
safe and our account with a supplier sit on supplier accounts: gold owed, not
stock. Which safe is which was written nowhere; the settings name two of them
and the employees their custody safes.

Filled where NULL, on gold safes only:
- showroom: settings.sale_gold_safe_box_id;
- scrap: settings.main_scrap_gold_safe_box_id, and any gold safe whose account
  shares the parent of that safe's account (the reserve scrap safe);
- custody: every employee's gold_safe_box_id.
Any other gold safe stays NULL -- not stock -- until the owner names it.

IMPACT: one nullable column on safe_box and its values. No entry, balance or
ledger row changes; the nightly check INVENTORY_LEDGER_DRIFT reads it.
Downgrade drops the column.

Revision ID: 20261013_stock_location
Revises: 20261012_historical_invoice_line
Create Date: 2026-10-13
"""
from alembic import op
import sqlalchemy as sa

revision = '20261013_stock_location'
down_revision = '20261012_historical_invoice_line'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    columns = {c['name'] for c in sa.inspect(bind).get_columns('safe_box')}
    if 'stock_location' not in columns:
        op.add_column('safe_box', sa.Column('stock_location', sa.String(20), nullable=True))

    def name(kind, where):
        return bind.execute(sa.text(
            f"UPDATE safe_box SET stock_location = '{kind}' "
            f"WHERE stock_location IS NULL AND safe_type = 'gold' AND ({where})")).rowcount

    showroom = name('showroom', 'id IN (SELECT sale_gold_safe_box_id FROM settings)')
    scrap = name('scrap', 'id IN (SELECT main_scrap_gold_safe_box_id FROM settings) OR account_id IN ('
                          'SELECT a.id FROM account a JOIN account m ON m.parent_id = a.parent_id '
                          'JOIN safe_box s ON s.account_id = m.id '
                          'WHERE s.id IN (SELECT main_scrap_gold_safe_box_id FROM settings))')
    custody = name('custody', 'id IN (SELECT gold_safe_box_id FROM employee WHERE gold_safe_box_id IS NOT NULL)')
    print(f'[stock_location] showroom {showroom}, scrap {scrap}, custody {custody}')


def downgrade():
    op.drop_column('safe_box', 'stock_location')
