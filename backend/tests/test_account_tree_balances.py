"""The chart's balances are the server's -- a parent's is all under it, its own entries too (CHART-UI-1, phase 1).

The «شجرة الحسابات» screen summed a parent's balance from its children, on the
device, and left the parent's own entries out: on the production copy nine
parents carry their own, 51 (7,378,721.47), 2100 (-6,228,279.97), 41 «إيرادات
النشاط» (-4,896,846.99) among them -- the tree's revenue short by 4.9 million.
A balance is a business answer: the server gives each parent its subtree's
(own entries and every descendant's), and the screen shows it.

And an account's type is one of five, however a writer spells it: the
employee custody and advance helpers wrote 'asset', so nine accounts of
production matched no type filter and showed no Arabic type.

Run:
    python -m pytest tests/test_account_tree_balances.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(name, parent=None, kind='Asset', weight=False):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**8}', name=name, type=kind, tracks_weight=weight,
                parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _post(lines):
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:8]}', date=datetime(2026, 5, 1), description='اختبار',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='اختبار', **cols))
    db.session.flush()


def test_an_account_type_is_one_of_five_however_it_is_spelled():
    assert _account('عهدة', kind='asset').type == 'Asset'
    assert _account('مصروف', kind='EXPENSE').type == 'Expense'
    assert _account('دائن', kind='liability').type == 'Liability'


def test_a_parents_balance_is_its_own_and_all_under_it(auth_headers):
    root = _account('جذر اختبار')
    parent = _account('أب له قيوده', parent=root)
    child = _account('ابن', parent=parent)
    gold = _account('ابن وزني', parent=parent, weight=True)
    other = _account('مقابل')
    _post([(parent, {'cash_debit': 100}), (other, {'cash_credit': 100})])          # the parent's own
    _post([(child, {'cash_debit': 50}), (other, {'cash_credit': 50})])
    _post([(gold, {'debit_18k': 7}), (other, {'credit_18k': 7})])                  # 6 g at the main karat

    rows = {a['id']: a for a in flask_app.test_client().get('/api/accounts', headers=auth_headers).get_json()}

    assert rows[parent.id]['balances']['cash'] == 100.0, "its own, as before"
    assert rows[parent.id]['subtree_balances']['cash'] == 150.0, 'its own and its children'
    assert rows[root.id]['subtree_balances']['cash'] == 150.0
    assert rows[parent.id]['subtree_balances']['weight_total'] == pytest.approx(6.0)
    assert rows[parent.id]['has_own_balance'] is True
    assert rows[root.id]['has_own_balance'] is False
    assert 'subtree_balances' not in rows[child.id] or rows[child.id]['subtree_balances'] is None, 'a leaf has none'
