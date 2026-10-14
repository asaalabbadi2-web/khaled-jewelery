"""employee_accounts: an employee's accounts by explicit link; the employee structure by role (CHART-002 step 3)

SCHEMA + DATA. The owner, 14 Oct 2026 (option (a) on both: the chart is data,
the links explicit).

- Table employee_account (employee_id, role, account_id), one row per
  (employee, role): salary_payable, commission_payable, eos_payable,
  bonus_payable. The code found these by the employee's name under a parent
  known by its number -- filled here by that very rule, frozen: the account
  named «ح/ذمم الموظف <name> - <category>» directly under 2400 / 2410 / 2420 /
  2310. On the production copy: 27 links, every one an exact match (the 7th
  employee has no bonus account yet; it is made at their first approval).
- The structure becomes roles (default operation), mapped to the accounts the
  code used: employee_personal_parent 1700, employee_salary_payable_parent
  2400, employee_commission_payable_parent 2410, employee_eos_payable_parent
  2420, employee_bonus_payable_parent 2310, employee_gold_custody_parent
  71310001, employee_cash_custody_parent 1100001, salary_expense 5410,
  bonus_expense 5401 (the old finder: the settings' number, else an expense
  named like «مصروف مكافأ», else 5401, 5450..). The employee-advances parent
  (1710) is not carried: the advances system was cancelled, and 1710 is
  «حساب جسر المشتريات» on production.

A role already mapped, an account missing, or a link already written is left
alone. Idempotent.

Impact: one new table; rows in accounting_mapping (created_by 'CHART-002').
No account, entry or balance changes. Downgrade drops the table and removes
exactly these roles' rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_employee_accounts'
down_revision = '20261014_core_roles'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
MARK = 'CHART-002'
STRUCTURE = (
    ('employee_personal_parent', ['1700']),
    ('employee_salary_payable_parent', ['2400']),
    ('employee_commission_payable_parent', ['2410']),
    ('employee_eos_payable_parent', ['2420']),
    ('employee_bonus_payable_parent', ['2310', '2311', '2312']),
    ('employee_gold_custody_parent', ['71310001']),
    ('employee_cash_custody_parent', ['1100001']),
    ('salary_expense', ['5410']),
)
BONUS_EXPENSE_NUMBERS = ['5401', '5450', '5451', '5452', '5455', '5491', '5492']
LINKS = (('salary_payable', '2400', 'رواتب'), ('commission_payable', '2410', 'عمولات'),
         ('eos_payable', '2420', 'نهاية الخدمة'), ('bonus_payable', '2310', 'مكافآت'))


def _mapped(bind, role):
    return bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o AND account_type = :r '
                                'AND is_active'), {'o': DEFAULT_OPERATION, 'r': role}).first() is not None


def _map(bind, role, account_id):
    bind.execute(sa.text(
        'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, created_at) '
        'VALUES (:o, :r, :a, true, :m, :t)'),
        {'o': DEFAULT_OPERATION, 'r': role, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})


def _by_number(bind, number):
    return bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n'), {'n': number}).scalar()


def _bonus_expense(bind):
    """The old finder (bonus_routes._find_bonus_expense_account), frozen."""
    settings_no = bind.execute(sa.text('SELECT bonus_expense_account_number FROM settings ORDER BY id LIMIT 1')).scalar()
    if settings_no:
        found = _by_number(bind, str(settings_no))
        if found:
            return found
    found = bind.execute(sa.text(
        "SELECT id FROM account WHERE type IN ('Expense', 'expense') AND ("
        "name ILIKE '%مصروف%مكافأ%' OR name ILIKE '%مكافأ%مصروف%' OR name ILIKE '%مصروف%مكافئ%' "
        "OR name ILIKE '%مكافئ%مصروف%' OR name ILIKE '%bonus%expense%' OR name ILIKE '%expense%bonus%') "
        "ORDER BY id LIMIT 1")).scalar()
    if found:
        return found
    for number in BONUS_EXPENSE_NUMBERS:
        found = bind.execute(sa.text("SELECT id FROM account WHERE account_number = :n AND type IN "
                                     "('Expense', 'expense')"), {'n': number}).scalar()
        if found:
            return found
    return None


def upgrade():
    op.create_table(
        'employee_account',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id', ondelete='CASCADE'), nullable=False),
        sa.Column('role', sa.String(40), nullable=False),
        sa.Column('account_id', sa.Integer(), sa.ForeignKey('account.id'), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100)),
        sa.UniqueConstraint('employee_id', 'role', name='uq_employee_account_role'),
    )
    op.create_index('ix_employee_account_employee_id', 'employee_account', ['employee_id'])
    bind = op.get_bind()

    mapped = []
    for role, numbers in STRUCTURE:
        if _mapped(bind, role):
            continue
        account_id = next((a for a in (_by_number(bind, n) for n in numbers) if a), None)
        if account_id:
            _map(bind, role, account_id)
            mapped.append(role)
    if not _mapped(bind, 'bonus_expense'):
        account_id = _bonus_expense(bind)
        if account_id:
            _map(bind, 'bonus_expense', account_id)
            mapped.append('bonus_expense')

    linked = 0
    employees = bind.execute(sa.text('SELECT id, name FROM employee ORDER BY id')).fetchall()
    for role, parent_number, category in LINKS:
        parent_id = _by_number(bind, parent_number)
        if not parent_id:
            continue
        for employee in employees:
            name = f'ح/ذمم الموظف {employee.name} - {category}'.strip()
            account_id = bind.execute(sa.text('SELECT id FROM account WHERE parent_id = :p AND name = :n ORDER BY id'),
                                      {'p': parent_id, 'n': name}).scalar()
            if not account_id:
                continue
            exists = bind.execute(sa.text('SELECT 1 FROM employee_account WHERE employee_id = :e AND role = :r'),
                                  {'e': employee.id, 'r': role}).first()
            if exists:
                continue
            bind.execute(sa.text('INSERT INTO employee_account (employee_id, role, account_id, created_at, created_by) '
                                 'VALUES (:e, :r, :a, :t, :m)'),
                         {'e': employee.id, 'r': role, 'a': account_id, 't': datetime.utcnow(), 'm': MARK})
            linked += 1
    print(f'[employee_accounts] roles mapped {mapped}; links {linked}')


def downgrade():
    op.drop_index('ix_employee_account_employee_id', table_name='employee_account')
    op.drop_table('employee_account')
    roles = [r for r, _ in STRUCTURE] + ['bonus_expense']
    op.get_bind().execute(
        sa.text('DELETE FROM accounting_mapping WHERE created_by = :m AND operation_type = :o AND account_type = ANY(:r)'),
        {'m': MARK, 'o': DEFAULT_OPERATION, 'r': roles})
