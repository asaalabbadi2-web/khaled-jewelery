"""The manager's dashboard says each purchase, and the weight of what it says (DASH-3).

The owner, 30 Oct 2026, agreeing to all advised:
- «هل هناك تفريق في المشتريات بين شراء الجديد والكسر (شراء كسر وتسكيرات)»:
  the summary's «المشتريات» was new gold only and «الكسر» mixed a customer's
  scrap with an office's settlement -- and the period's card said neither.
  Now three: new (a supplier), scrap (a customer), settlements (an office).
- «المصروفات والإيرادات الوزنية هل يجب أن تظهر في الملخص»: the expenses said
  riyals alone. Now each says its grams too -- the weight twin's lines, main
  karat -- and the revenues the gram profit counts (the owner's marks) are a tab.

Run:
    python -m pytest tests/test_dashboard_says_each_purchase_and_the_weight.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import Account, Invoice, JournalEntry, JournalEntryLine, Office, db
from tests.test_dashboard_expenses_are_operating import _account, _child, _entry


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _month(client, headers):
    return client.get('/api/dashboard/admin', headers=headers).get_json()['sales_purchases_summary']['month']


def _invoice(invoice_type, total, weight, **kw):
    inv = Invoice(invoice_type=invoice_type, invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=datetime.now(),
                  total=total, total_weight=weight, is_posted=True, posted_by='admin', **kw)
    db.session.add(inv)
    db.session.flush()
    return inv


def _values(month, key):
    part = month.get(key) or {}
    return part.get('total_value', 0.0), part.get('total_weight', 0.0), part.get('docs', 0)


def test_new_gold_scrap_and_settlements_are_three(app, auth_headers):
    client = app.test_client()
    before = _month(client, auth_headers)
    office = Office(office_code=f'OFF-D3-{uuid.uuid4().hex[:6]}', name=f'مكتب {uuid.uuid4().hex[:4]}', active=True)
    db.session.add(office)
    db.session.flush()
    _invoice('شراء', 9000.0, 20.0, gold_type='new')                       # a supplier's new gold
    _invoice('شراء من عميل', 4200.0, 10.0, gold_type='scrap')             # a customer's scrap
    _invoice('شراء', 8400.0, 20.0, gold_type='scrap', office_id=office.id)  # an office's settlement
    after = _month(client, auth_headers)

    def moved(key):
        a, b = _values(after, key), _values(before, key)
        return tuple(round(x - y, 3) for x, y in zip(a, b))
    assert moved('purchases') == (9000.0, 20.0, 1), 'new gold, from a supplier'
    assert moved('scrap_customers') == (4200.0, 10.0, 1), 'scrap, from a customer'
    assert moved('office_settlements') == (8400.0, 20.0, 1), 'a settlement, at an office'


def test_the_expenses_say_their_grams_and_the_revenues_are_said(app, auth_headers):
    from pricing.gold_price_service import get_main_karat
    client = app.test_client()
    before = _month(client, auth_headers)
    expenses = _account('5', 'المصروفات')
    operating = _account('52', 'مصاريف تشغيلية', expenses)
    rent = _child(operating, 'إيجار وزني اختبار')
    twin = Account(account_number=f'7{rent.account_number}', name='إيجار وزني اختبار وزني', type='Expense',
                   tracks_weight=True, transaction_type='gold')
    from accounting.chart_tree import REVENUE_ROOT, role_account_id
    revenue = Account(account_number=f'4{uuid.uuid4().int % 10**6:06d}', name='إيراد موسوم اختبار',
                      type='Revenue', include_in_gram_profit=True, parent_id=role_account_id(REVENUE_ROOT))
    cash = Account(account_number=f'9{uuid.uuid4().hex[:6]}', name='صندوق', type='Asset')
    db.session.add_all([twin, revenue, cash])
    db.session.flush()
    rent.memo_account_id = twin.id
    db.session.flush()
    _entry(rent, cash, debit=1000.0)
    je = JournalEntry(entry_number=f'JE-W-{uuid.uuid4().hex[:8]}', date=datetime.now(), description='وزني',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=twin.id, debit_21k=2.0, description='وزني'))
    db.session.flush()
    _entry(revenue, cash, credit=300.0)
    after = _month(client, auth_headers)

    main = float(get_main_karat())
    assert after['expenses']['total_value'] - before['expenses']['total_value'] == pytest.approx(1000.0)
    assert after['expenses']['total_weight'] - before['expenses'].get('total_weight', 0.0) == pytest.approx(2.0 * 21 / main)
    assert after['revenues']['total_value'] - before.get('revenues', {}).get('total_value', 0.0) == pytest.approx(300.0)


def test_the_dashboard_is_the_manager_s_alone(app):
    """The owner, 30 Oct 2026: «لماذا المحاسب؟ ألا يجب أن تكون للمدير فقط؟» -- it
    was the financial reports', which the accountant holds."""
    from flask import g
    from auth_decorators import generate_token
    from models import AppUser
    client = app.test_client()

    def status(role):
        user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
        db.session.add(user)
        db.session.flush()
        g.pop('current_user', None)
        return client.get('/api/dashboard/admin', headers={'Authorization': f'Bearer {generate_token(user)}'}).status_code
    assert status('manager') == 200
    assert status('accountant') == 403
