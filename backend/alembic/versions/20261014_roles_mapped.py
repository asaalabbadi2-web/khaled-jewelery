"""roles_mapped: every role the postings ask for is a mapping, not a number (CHART-002)

DATA, written once. The owner, 14 Oct 2026 (CHART-002 step 1: the code asks for
an account by its role). The code stops guessing: no account number or name
stands in for an unmapped role, no account is created on the fly. So that
nothing posts differently, each required role the mappings did not resolve is
mapped here to the account the old fallback found -- on the production copy,
eleven roles:

  بيع / manufacturing_wage, مرتجع بيع / manufacturing_wage   -> 510
  بيع / sales_gold_scrap                                    -> 401
  شراء / manufacturing_wage_inventory                       -> 1320
  شراء, شراء من عميل / purchases_gold; شراء من عميل / purchases_gold_new -> 511
  شراء من عميل / purchases_gold_scrap                       -> 512
  مرتجع بيع / sales_returns                                 -> 420
  مرتجع شراء, مرتجع شراء (مورد) / purchase_returns          -> 513

«operating_expenses» fell back on 51 «تكلفة المبيعات»; it is asked only when
manufacturing_wage is not mapped, which it now is -- not carried.

The lists below are the fallback as it stood, frozen: this migration says what
production resolved, it is not read by the application. A role that resolves
already, or whose fallback finds nothing, is left alone. Idempotent.

Impact: rows in accounting_mapping only (created_by 'CHART-002'); no entry,
balance or account changes. Downgrade removes exactly those rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_roles_mapped'
down_revision = '20261014_buy_price_ratio'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
KARATS = ('inventory_18k', 'inventory_21k', 'inventory_22k', 'inventory_24k')
REQUIRED = (
    *((DEFAULT_OPERATION, r) for r in ('inventory_count_shortage', 'inventory_count_surplus')),
    *(('بيع', r) for r in ('cash', 'commission', 'commission_vat', *KARATS, 'manufacturing_wage', 'revenue',
                           'sales_gold_new', 'sales_gold_scrap', 'vat_payable', 'vat_receivable')),
    *(('تسوية_مورد', r) for r in ('supplier_settlement_expense', 'supplier_settlement_income',
                                  'supplier_weight_settlement_expense', 'supplier_weight_settlement_income')),
    *(('شراء', r) for r in ('cash', *KARATS, 'manufacturing_wage_inventory', 'purchases_gold', 'suppliers',
                            'vat_receivable')),
    *(('شراء من عميل', r) for r in ('cash', *KARATS, 'purchases_gold', 'purchases_gold_new',
                                    'purchases_gold_scrap', 'vat_receivable')),
    *(('مرتجع بيع', r) for r in ('cash', 'customers', *KARATS, 'manufacturing_wage', 'sales_returns')),
    *(('مرتجع شراء', r) for r in ('cash', 'customers', *KARATS, 'purchase_returns')),
    ('مرتجع شراء (مورد)', 'purchase_returns'),
)
ALIASES = {'cost_of_sales': ['cost'], 'cost': ['cost_of_sales'],
           'sales_gold_new': ['revenue'], 'revenue': ['sales_gold_new']}
NUMBERS = {
    'inventory_18k': ['1300'], 'inventory_21k': ['1220', '1310'], 'inventory_22k': ['1320'],
    'inventory_24k': ['1200', '1330', '1340'], 'manufacturing_wage_inventory': ['1340', '1350', '1320'],
    'cash': ['15', '1100'], 'customers': ['1200'], 'suppliers': ['210'],
    'revenue': ['400', '40'], 'sales_gold_new': ['400', '40'], 'sales_gold_scrap': ['401'],
    'sales_returns': ['420', '400', '40'], 'purchases_gold': ['511', '512', '510', '51'],
    'purchases_gold_new': ['511', '510', '51'], 'purchases_gold_scrap': ['512', '511', '510'],
    'purchase_returns': ['513', '512', '511', '50'], 'commission': ['5150'], 'manufacturing_wage': ['510'],
}
NAMES = {
    'cash': ['صندوق النقدية'], 'sales_gold_new': ['مبيعات ذهب جديد'], 'sales_gold_scrap': ['مبيعات ذهب كسر'],
    'revenue': ['مبيعات ذهب جديد'], 'inventory_21k': ['مخزون ذهب عيار 21'],
    'inventory_24k': ['مخزون ذهب عيار 24'], 'suppliers': ['موردو ذهب'], 'customers': ['أرصدة ذهب العملاء'],
}


def _mapped(bind, operation, role):
    for r in [role] + ALIASES.get(role, []):
        for op_ in (operation, DEFAULT_OPERATION):
            if bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o '
                                    'AND account_type = :r AND is_active'), {'o': op_, 'r': r}).first():
                return True
    return False


def _fallback(bind, role):
    for number in NUMBERS.get(role, ()):
        found = bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n'), {'n': number}).scalar()
        if found:
            return found, number
    for name in NAMES.get(role, ()):
        found = bind.execute(sa.text('SELECT id, account_number FROM account WHERE name = :n ORDER BY id'),
                             {'n': name}).first()
        if found:
            return found.id, found.account_number
    return None, None


def upgrade():
    bind = op.get_bind()
    made = []
    for operation, role in REQUIRED:
        if _mapped(bind, operation, role):
            continue
        account_id, number = _fallback(bind, role)
        if account_id is None:
            continue
        bind.execute(sa.text(
            'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, '
            'created_at) VALUES (:o, :r, :a, true, :m, :t)'),
            {'o': operation, 'r': role, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})
        made.append(f'{operation}/{role}->{number}')
    print(f'[roles_mapped] {len(made)} mapped: {made}')


def downgrade():
    op.get_bind().execute(sa.text('DELETE FROM accounting_mapping WHERE created_by = :m'), {'m': MARK})
