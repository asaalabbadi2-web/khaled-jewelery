"""live_roles: the last live accounts found by number become roles (CHART-002 release 5b)

DATA ONLY. Roles of the default operation, mapped to the account the code found
first by number -- the order frozen here:

- opening_balance_equity -- 32, 31, 3600 (a supplier's opening balance from the
  offices screen). On the production copy: 32 «أرباح/خسائر محتجزة».
- cash_root -- 1100 «النقدية»: its linked twin (71100) is the cash weight side
  an invoice and a weight-closing profile fell back on as the number 71100.
- vat_settlement -- 2301, the VAT return's net owed to the authority: it exists
  on production, unmapped (the code mapped it at the first filing).
- vat_settlement_parent -- 230, vat_non_recoverable_parent -- 540: where the
  code makes those two accounts once when unmapped.

A role already mapped, or with no account found, is left alone. Idempotent.

Impact: rows in accounting_mapping (created_by 'CHART-002'). No account, entry
or balance changes. Downgrade removes exactly these roles' rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261015_live_roles'
down_revision = '20261015_report_groups'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
ROLES = (('opening_balance_equity', ['32', '31', '3600']), ('cash_root', ['1100']), ('vat_settlement', ['2301']),
         ('vat_settlement_parent', ['230']), ('vat_non_recoverable_parent', ['540']))


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
    print(f'[live_roles] roles mapped {mapped}')


def downgrade():
    op.get_bind().execute(
        sa.text('DELETE FROM accounting_mapping WHERE created_by = :m AND operation_type = :o AND account_type = ANY(:r)'),
        {'m': MARK, 'o': DEFAULT_OPERATION, 'r': [r for r, _ in ROLES]})
