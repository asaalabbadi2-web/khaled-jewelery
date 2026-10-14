"""gold_roles: the gold's inventory, the weight closing's bridge, the karat-difference commission by role (CHART-002 step 4)

DATA ONLY. Five roles of the default operation, mapped to the accounts the code
found by number until now -- the rule frozen here:

- gold_inventory_new / gold_inventory_scrap -- the invoices' finder
  (_resolve_inventory_account_id_for_invoice): the weight-closing settings'
  inventory_new_account_id / inventory_scrap_account_id (the scrap falling back
  on the older inventory_account_id), a chart number first, a row id second;
  else 1300 / 1310. On the production copy the settings are empty: 1300 «مخزون
  الذهب ـ معروض للبيع», 1310 «مخزون الذهب ـ كسر». The weight closing's own
  finder -- 1310 for both, as a row id first -- is not carried: its path never
  posted on production, and new gold's cost leaves the new gold's inventory.
- weight_closing_bridge -- 1710, else 1290, else the account named «جسر مشتريات
  الكسر والتسكير». On the copy: 1710 «حساب جسر المشتريات».
- karat_diff_revenue -- 4110, else the account named «إيرادات عمولة السداد بذهب
  صافي» (the code made it when missing). On the copy: 4110 «خصم السداد بعيار
  أعلى». Both the karat-difference commission earned and the 24k net-gold
  settlement's commission credit it.
- karat_diff_expense -- 5240, else the account named «رسوم السداد بعيار أقل».
  On the copy: 5240.

A role already mapped, or with no account found, is left alone. Idempotent.

Impact: rows in accounting_mapping (created_by 'CHART-002'). No account, entry
or balance changes. Downgrade removes exactly these roles' rows.
"""
import json
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_gold_roles'
down_revision = '20261014_employee_accounts'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
ROLES = ('gold_inventory_new', 'gold_inventory_scrap', 'weight_closing_bridge',
         'karat_diff_revenue', 'karat_diff_expense')


def _mapped(bind, role):
    return bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o AND account_type = :r '
                                'AND is_active'), {'o': DEFAULT_OPERATION, 'r': role}).first() is not None


def _map(bind, role, account_id):
    bind.execute(sa.text(
        'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, created_at) '
        'VALUES (:o, :r, :a, true, :m, :t)'),
        {'o': DEFAULT_OPERATION, 'r': role, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})


def _by_number(bind, number):
    return bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n ORDER BY id'),
                        {'n': str(number)}).scalar()


def _by_name(bind, name):
    return bind.execute(sa.text('SELECT id FROM account WHERE name = :n ORDER BY id'), {'n': name}).scalar()


def _weight_closing_settings(bind):
    raw = bind.execute(sa.text('SELECT weight_closing_settings FROM settings ORDER BY id LIMIT 1')).scalar()
    try:
        payload = json.loads(raw) if raw else {}
    except (TypeError, ValueError):
        payload = {}
    return payload if isinstance(payload, dict) else {}


def _setting_account(bind, value):
    """The invoices' finder, frozen: a chart number first, a row id second."""
    if value in (None, '', 0, False):
        return None
    try:
        v = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    if v <= 0:
        return None
    return _by_number(bind, v) or bind.execute(sa.text('SELECT id FROM account WHERE id = :i'), {'i': v}).scalar()


def _inventory(bind, settings, kind):
    preferred = settings.get('inventory_scrap_account_id' if kind == 'scrap' else 'inventory_new_account_id')
    if preferred in (None, '', 0, False) and kind == 'scrap':
        preferred = settings.get('inventory_account_id')
    return _setting_account(bind, preferred) or _by_number(bind, '1310' if kind == 'scrap' else '1300')


def upgrade():
    bind = op.get_bind()
    settings = _weight_closing_settings(bind)
    found = {
        'gold_inventory_new': lambda: _inventory(bind, settings, 'new'),
        'gold_inventory_scrap': lambda: _inventory(bind, settings, 'scrap'),
        'weight_closing_bridge': lambda: (_by_number(bind, '1710') or _by_number(bind, '1290')
                                          or _by_name(bind, 'جسر مشتريات الكسر والتسكير')),
        'karat_diff_revenue': lambda: _by_number(bind, '4110') or _by_name(bind, 'إيرادات عمولة السداد بذهب صافي'),
        'karat_diff_expense': lambda: _by_number(bind, '5240') or _by_name(bind, 'رسوم السداد بعيار أقل'),
    }
    mapped = []
    for role in ROLES:
        if _mapped(bind, role):
            continue
        account_id = found[role]()
        if account_id:
            _map(bind, role, account_id)
            mapped.append(role)
    print(f'[gold_roles] roles mapped {mapped}')


def downgrade():
    op.get_bind().execute(
        sa.text('DELETE FROM accounting_mapping WHERE created_by = :m AND operation_type = :o AND account_type = ANY(:r)'),
        {'m': MARK, 'o': DEFAULT_OPERATION, 'r': list(ROLES)})
