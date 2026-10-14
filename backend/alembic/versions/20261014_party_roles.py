"""party_roles: the parents a customer's, a supplier's and an office's account are made under, by role (CHART-002 step 4b)

DATA ONLY. Three roles of the default operation, mapped to the account the code
found first by number until now -- the order frozen here:

- customer_accounts_parent -- 1200, 1100, 120, 110 (the customer route's
  fallback). On the production copy: 1200 «عملاء مجوهرات خالد».
- supplier_accounts_parent -- 2100, 210, 21, 21100, 2110, 211, 2200, 220 (the
  supplier service's; it normalised 210 to 2100). On the copy: 2100 «حسابات
  موردو الذهب المشغول».
- office_accounts_parent -- 2100, 210, 21, 2200, 220, 21100, 211 (the office
  service's). On the copy: 2100 -- an office is a supplier too.

A role already mapped, or with no account found, is left alone. Idempotent.

Impact: rows in accounting_mapping (created_by 'CHART-002'). No account, entry
or balance changes. Downgrade removes exactly these roles' rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_party_roles'
down_revision = '20261014_gold_roles'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
ROLES = (
    ('customer_accounts_parent', ['1200', '1100', '120', '110']),
    ('supplier_accounts_parent', ['2100', '210', '21', '21100', '2110', '211', '2200', '220']),
    ('office_accounts_parent', ['2100', '210', '21', '2200', '220', '21100', '211']),
)


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
    print(f'[party_roles] roles mapped {mapped}')


def downgrade():
    op.get_bind().execute(
        sa.text('DELETE FROM accounting_mapping WHERE created_by = :m AND operation_type = :o AND account_type = ANY(:r)'),
        {'m': MARK, 'o': DEFAULT_OPERATION, 'r': [r for r, _ in ROLES]})
