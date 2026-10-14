"""CHART-001: the chart put in order (the owner, 12 Oct 2026: «صحح الجميع»).

- 2310 (employees' bonuses payable) and 2320 (end-of-service provision) sat
  under 230 «ضريبة القيمة المضافة المستحقة»: they move, numbered as they are,
  to 24 «أرصدة دائنة أخرى» -- and the code that creates 2310 creates it there
  (the 2027 database is built afresh, ADR-044). 2310 is named for what it holds.
- 235 «الزكاة المستحقة» under 23.
- The weight twins of the families that never hold gold -- input VAT (14),
  collections (15), tax liabilities and bonuses (23), employee payables (24) --
  stop, and an employee's cash accounts get no twin from now on.
- 72 «الخصوم وزني» is a liability, 74 «الإيرادات وزني» a revenue; 510 never
  carried gold and is not a weight account.

Run:
    python -m pytest tests/test_chart_001.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, db
from services.repair import chart_001

NOW = datetime(2026, 10, 12, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _acc(number, name='حساب', type_='Liability', parent=None, weight=False, memo=None):
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        a = Account(account_number=number, name=name, type=type_, tracks_weight=weight)
        db.session.add(a)
    if parent is not None:
        a.parent_id = parent.id
    if memo is not None:
        a.memo_account_id = memo.id
    db.session.flush()
    return a


def test_bonuses_and_end_of_service_move_to_other_credit_balances_numbered_as_they_are():
    two = _acc('2', 'الخصوم')
    tax = _acc('23', 'الالتزامات الضريبية', parent=two)
    vat = _acc('230', 'ضريبة القيمة المضافة المستحقة', parent=tax)
    other = _acc('24', 'أرصدة دائنة أخرى', parent=two)
    bonuses = _acc('2310', 'عولات بائعين ومشترين مستحقة', parent=vat)
    child = _acc(f'2310{uuid.uuid4().int % 1000:03d}', 'ح/ذمم موظف - مكافآت', parent=bonuses)
    eos = _acc('2320', 'مخصص مكافئة نهاية الخدمة', parent=vat)

    plan = chart_001.apply(by='t', now=NOW, dry_run=True, steps=['move'])
    assert plan['move']['moved'] == ['2310', '2320'] and bonuses.parent_id == vat.id, 'dry run writes nothing'
    chart_001.apply(by='t', now=NOW, dry_run=False, steps=['move'])
    assert bonuses.parent_id == other.id and eos.parent_id == other.id
    assert child.parent_id == bonuses.id and bonuses.account_number == '2310', 'numbers and children as they were'
    assert bonuses.name == 'مكافآت مستحقة للموظفين'
    assert chart_001.apply(by='t', now=NOW, dry_run=True, steps=['move'])['move']['moved'] == []


def test_the_code_creates_no_2310_the_bonus_parent_is_its_role():
    """It created 2310 under 24 when missing; the chart is data now (CHART-002,
    ADR-046): the bonus payables' parent is the mapped role, whatever its number."""
    from employee_account_helpers import ensure_employee_group_accounts
    existing = Account.query.filter_by(account_number='2310').first()
    existing.account_number = f'x{uuid.uuid4().hex[:6]}'
    db.session.flush()
    ensured = ensure_employee_group_accounts(created_by='t')
    assert ensured['employee_bonus_payable_parent'].id == existing.id
    assert Account.query.filter_by(account_number='2310').first() is None


def test_an_employee_cash_account_gets_no_weight_twin():
    from employee_account_helpers import get_or_create_employee_payables_accounts
    from models import Employee
    employee = Employee(employee_code=f'E-C-{uuid.uuid4().hex[:6]}', name=f'موظف {uuid.uuid4().hex[:4]}',
                        is_active=True)
    db.session.add(employee)
    db.session.flush()
    made = get_or_create_employee_payables_accounts(employee, created_by='t')
    assert made, 'its payables were made'
    assert all(a.memo_account_id is None for a in made), 'cash only: no twin'


def test_zakat_payable_under_tax_liabilities():
    two = _acc('2', 'الخصوم')
    tax = _acc('23', 'الالتزامات الضريبية', parent=two)
    chart_001.apply(by='t', now=NOW, dry_run=False, steps=['zakat'])
    z = Account.query.filter_by(account_number='235').one()
    assert z.parent_id == tax.id and z.name == 'الزكاة المستحقة' and z.type == 'Liability' and not z.tracks_weight


def test_the_twins_of_families_that_never_hold_gold_stop_and_a_used_one_is_kept():
    from models import JournalEntry, JournalEntryLine
    fin = _acc(f'15{uuid.uuid4().int % 10**5:05d}', 'مدى', type_='Asset')
    twin = _acc(f'7{fin.account_number}', 'مدى وزني', type_='Asset', weight=True)
    fin.memo_account_id = twin.id
    used_fin = _acc(f'24{uuid.uuid4().int % 10**5:05d}', 'ذمم', type_='Liability')
    used_twin = _acc(f'7{used_fin.account_number}', 'ذمم وزني', weight=True)
    used_fin.memo_account_id = used_twin.id
    other = _acc(f'99{uuid.uuid4().int % 10**5:05d}', 'مقابل', type_='Asset')
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:6]}', date=NOW, description='t', entry_type='عادي',
                      reference_type='manual', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=used_twin.id, debit_21k=1.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, credit_21k=1.0)])
    db.session.flush()

    plan = chart_001.apply(by='t', now=NOW, dry_run=False, steps=['twins'])
    db.session.refresh(twin)
    db.session.refresh(used_twin)
    assert twin.is_active is False
    assert used_twin.is_active is not False, 'a twin that carried gold is kept'
    assert used_twin.account_number in plan['twins']['kept_used']


def test_the_weight_roots_get_their_types_and_510_is_not_a_weight_account():
    liabilities_w = _acc('72', 'الخصوم وزني', type_='Asset', weight=True)
    revenues_w = _acc('74', 'الإيرادات وزني', type_='Asset', weight=True)
    wages = _acc('510', 'مصروفات أجور المصنعية', type_='Expense', weight=True)
    chart_001.apply(by='t', now=NOW, dry_run=False, steps=['types'])
    assert (liabilities_w.type, revenues_w.type, wages.tracks_weight) == ('Liability', 'Revenue', False)
