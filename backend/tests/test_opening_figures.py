"""A new year's opening figures beside the closing books (ADR-044, TR-2).

The owner, 6 Nov 2026: «شاشة افتتاح في النظام» -- a row for each asset or
liability account holding a balance, its weight twin in its row; what the
count gives is no row (a counted stock safe). The figure is empty until
entered («فارغة حتى تُؤكَّد») with its source, at two places; a party's cash
says whether it opens as gold at the closing price or stays cash waiting to be
closed («الاثنين معا»). The figures less the books are what equity takes. The
manager enters, the owner approves («المدير يُدخل، والمالك يعتمد»): approved
only once every row has its figure, then nothing changes.

Run:
    python -m pytest tests/test_opening_figures.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from auth_decorators import generate_token
from models import Account, AppUser, JournalEntry, JournalEntryLine, Supplier, db
from tests.test_stock_screens import _safe, _stock

NOW = datetime(2026, 12, 31, 20, 0)
YEAR = 2027


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _post(lines):
    je = JournalEntry(entry_number=f'JE-OP-{uuid.uuid4().hex[:8]}', date=NOW, description='رصيد', entry_type='عادي',
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='رصيد', **cols))
    db.session.flush()


@pytest.fixture
def books():
    """A cash account with 4,137.00; a supplier owed 1,500.00 and 290.30 g of
    24k on his twin; 250.00 on the suppliers' group itself; a counted
    showroom safe with 10 g."""
    from accounting.chart_tree import role_account_id
    from party_account_service import ensure_supplier_accounts
    # the suppliers' group under the liabilities, as on production (the test
    # chart seeds 210 without a parent); fenced, undone after the test
    suppliers = db.session.get(Account, role_account_id('supplier_payables_root'))
    root = db.session.get(Account, role_account_id('liabilities_root'))
    if suppliers.parent_id is None and suppliers.id != root.id:
        suppliers.parent_id = root.id
        twin, root_twin = db.session.get(Account, suppliers.memo_account_id), db.session.get(Account, root.memo_account_id)
        if twin is not None and root_twin is not None and twin.parent_id is None:
            twin.parent_id = root_twin.id
    db.session.flush()
    cash = Account(account_number=f'1100{uuid.uuid4().int % 10**4:04d}', name='حساب بنكي مؤقت OP', type='Asset',
                   transaction_type='cash', parent_id=role_account_id('cash_root'))
    db.session.add(cash)
    supplier = Supplier(supplier_code=f'SUP-{uuid.uuid4().hex[:6]}', name=f'مورد افتتاح {uuid.uuid4().hex[:4]}')
    db.session.add(supplier)
    db.session.flush()
    ensure_supplier_accounts(supplier)
    db.session.flush()
    own = db.session.get(Account, supplier.account_id)
    twin = db.session.get(Account, own.memo_account_id)
    other = Account(account_number=f'3{uuid.uuid4().int % 10**6:06d}', name='مقابل OP', type='Equity')
    db.session.add(other)
    db.session.flush()
    _post([(cash, {'cash_debit': 4137.0}), (own, {'cash_credit': 1500.0}), (other, {'cash_debit': -2637.0})])
    _post([(twin, {'credit_24k': 290.3}), (other, {'debit_24k': 290.3})])
    group = db.session.get(Account, own.parent_id)
    _post([(group, {'cash_credit': 250.0}), (other, {'cash_debit': 250.0})])
    showroom = _safe('showroom')
    _stock(showroom, 10.0)
    return {'cash': cash, 'supplier': own, 'twin': twin, 'group': group, 'showroom': showroom}


def _rows():
    from services.opening_figures import opening
    state = opening(YEAR)
    return state, {r['account_id']: r for r in state['rows']}


def test_a_row_for_each_account_holding_a_balance_its_twin_in_its_row(books):
    state, rows = _rows()
    cash = rows[books['cash'].id]
    assert cash['books']['cash'] == 4137.0 and cash['actual'] is None, 'empty until entered'
    supplier = rows[books['supplier'].id]
    assert (supplier['books']['cash'], supplier['books']['24']) == (-1500.0, -290.3)
    assert supplier['party'] is True and books['twin'].id not in rows, 'the twin is in its row'
    assert books['showroom'].account_id not in rows, 'the count gives it'
    assert rows[books['group'].id]['party'] is False, 'a group holding lines is a row, not a party (2100 on the copy)'
    assert state['entered'] < state['total']


def test_a_figure_has_its_source_two_places_and_a_party_s_cash_its_treatment(books):
    from services.opening_figures import OpeningRefused, enter
    with pytest.raises(OpeningRefused, match='مصدر'):
        enter(YEAR, books['cash'].id, cash=4137, karats={}, source=None, treatment=None, note=None, by='m', now=NOW)
    with pytest.raises(OpeningRefused, match='خانتين'):
        enter(YEAR, books['cash'].id, cash=4137.005, karats={}, source='statement', treatment=None, note=None,
              by='m', now=NOW)
    with pytest.raises(OpeningRefused, match='التسكير'):
        enter(YEAR, books['supplier'].id, cash=-1500, karats={'24': -290.3}, source='reconciliation',
              treatment=None, note=None, by='m', now=NOW)
    enter(YEAR, books['cash'].id, cash=4100, karats={}, source='statement', treatment=None, note='كشف البنك',
          by='m', now=NOW)
    enter(YEAR, books['supplier'].id, cash=-1500, karats={'24': -290.3}, source='reconciliation',
          treatment='gold', note=None, by='m', now=NOW)
    state, rows = _rows()
    assert rows[books['cash'].id]['difference']['cash'] == -37.0
    assert rows[books['supplier'].id]['treatment'] == 'gold'
    assert state['difference']['cash'] == pytest.approx(-37.0), 'what equity takes'


def test_approved_only_once_every_row_has_its_figure_then_nothing_changes(books):
    from services.opening_figures import OpeningRefused, approve, enter
    with pytest.raises(OpeningRefused, match='بلا رقم فعلي'):
        approve(YEAR, by='owner', now=NOW)
    _, rows = _rows()
    for row in rows.values():
        b = row['books']
        enter(YEAR, row['account_id'], cash=round(b['cash'], 2), karats={k: round(b[k], 2) for k in ('18', '21', '22', '24')},
              source='reconciliation', treatment='waiting' if row['party'] else None, note=None, by='m', now=NOW)
    approve(YEAR, by='owner', now=NOW)
    with pytest.raises(OpeningRefused, match='معتمد'):
        enter(YEAR, books['cash'].id, cash=1, karats={}, source='count', treatment=None, note=None, by='m', now=NOW)


def test_the_manager_enters_the_owner_approves(books):
    user = AppUser(username=f'manager-{uuid.uuid4().hex[:6]}', role='manager', is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    headers = {'Authorization': f'Bearer {generate_token(user)}'}
    client = flask_app.test_client()
    assert client.get(f'/api/opening/{YEAR}', headers=headers).status_code == 200
    resp = client.put(f'/api/opening/{YEAR}/{books["cash"].id}', headers=headers,
                      json={'cash': 4137, 'source': 'statement'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert client.post(f'/api/opening/{YEAR}/approve', headers=headers).status_code == 403
