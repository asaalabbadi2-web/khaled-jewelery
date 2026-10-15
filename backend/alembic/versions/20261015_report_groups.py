"""report_groups: the chart's groups the reports read, by role (CHART-002 release 5)

DATA ONLY. The income statement, the gold cost replay and its transition, the
gram profit, the inventory reconciliation, the analytics summary and the
weight income statement classified accounts by number prefixes ('4', '5', '51',
'13%', '74%', '75%', '7131%') and root numbers (71300, 7210, 752, 33...). Now
by the tree under roles of the default operation -- a weight group being the
linked twin of its financial group (74 of 4, 751 of 51, 7210 of 210):

  assets_root 1, liabilities_root 2, equity_root 3, revenue_root 4,
  expenses_root 5, operating_revenue_root 41, cost_of_sales_root 51,
  operating_expenses_root 52, gold_inventory_root 130,
  worked_gold_suppliers_root 210, valuation_equity 33.

On the production copy (12 Oct) every prefix the reports used is its group's
subtree exactly (13% = 130's, 4% = 4's, 74% = 74's, 75% = 75's, 7131% =
71310's) and every weight group is its financial group's linked twin.

A role already mapped, or with no account found, is left alone. Idempotent.

Impact: rows in accounting_mapping (created_by 'CHART-002'). No account, entry
or balance changes. Downgrade removes exactly these roles' rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261015_report_groups'
down_revision = '20261014_repair_protection'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
ROLES = (('assets_root', '1'), ('liabilities_root', '2'), ('equity_root', '3'), ('revenue_root', '4'),
         ('expenses_root', '5'), ('operating_revenue_root', '41'), ('cost_of_sales_root', '51'),
         ('operating_expenses_root', '52'), ('gold_inventory_root', '130'), ('worked_gold_suppliers_root', '210'),
         ('valuation_equity', '33'))


def upgrade():
    bind = op.get_bind()
    mapped = []
    for role, number in ROLES:
        if bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o AND account_type = :r '
                                'AND is_active'), {'o': DEFAULT_OPERATION, 'r': role}).first():
            continue
        account_id = bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n ORDER BY id'),
                                  {'n': number}).scalar()
        if account_id:
            bind.execute(sa.text(
                'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, '
                'created_at) VALUES (:o, :r, :a, true, :m, :t)'),
                {'o': DEFAULT_OPERATION, 'r': role, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})
            mapped.append(role)
    print(f'[report_groups] roles mapped {mapped}')


def downgrade():
    op.get_bind().execute(
        sa.text('DELETE FROM accounting_mapping WHERE created_by = :m AND operation_type = :o AND account_type = ANY(:r)'),
        {'m': MARK, 'o': DEFAULT_OPERATION, 'r': [r for r, _ in ROLES]})
