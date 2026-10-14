"""party_groups: the groups whose tree is what suppliers are owed and customers owe (CHART-002 step 4b2)

DATA ONLY. The party balance readers -- a supplier's and a customer's
statement, list and live balance -- kept the lines tagged to a party on shared
accounts by their number's prefix: Liability '21%', Asset '12%'. Now by the
tree under two roles of the default operation:

- supplier_payables_root -- 21 «الموردون». On the production copy (12 Oct) its
  Liability subtree is '21%' plus 220, 2200 and three old office accounts
  (2200000/2/3) -- with no line on any of them.
- customer_receivables_root -- 12 if it exists, else 120 «العملاء»: the copy has
  no 12, and 120's Asset subtree is '12%' exactly (45 accounts).

A role already mapped, or with no account found, is left alone. Idempotent.

Impact: rows in accounting_mapping (created_by 'CHART-002'). No account, entry
or balance changes. Downgrade removes exactly these roles' rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_party_groups'
down_revision = '20261014_party_roles'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
ROLES = (('supplier_payables_root', ['21']), ('customer_receivables_root', ['12', '120']))


def upgrade():
    bind = op.get_bind()
    mapped = []
    for role, numbers in ROLES:
        if bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o AND account_type = :r '
                                'AND is_active'), {'o': DEFAULT_OPERATION, 'r': role}).first():
            continue
        account_id = next((a for a in (bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n '
                                                            'ORDER BY id'), {'n': n}).scalar() for n in numbers)
                           if a), None)
        if account_id:
            bind.execute(sa.text(
                'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, '
                'created_at) VALUES (:o, :r, :a, true, :m, :t)'),
                {'o': DEFAULT_OPERATION, 'r': role, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})
            mapped.append(role)
    print(f'[party_groups] roles mapped {mapped}')


def downgrade():
    op.get_bind().execute(
        sa.text('DELETE FROM accounting_mapping WHERE created_by = :m AND operation_type = :o AND account_type = ANY(:r)'),
        {'m': MARK, 'o': DEFAULT_OPERATION, 'r': [r for r, _ in ROLES]})
