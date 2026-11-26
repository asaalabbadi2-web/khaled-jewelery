"""The main karat is not changed once the books carry a weight (D9, the owner; ADR-105).

Every weight the books equate is written in the main karat at its writing --
the memo accounts' debit_weight and credit_weight (dual_system_helpers), the
weight_main_karat columns, the analytics -- and is never rewritten: a main
karat changed after them mixes two units in one ledger, and no report could
tell them apart. The laws, in _apply_settings (PUT and PATCH):
  - once any journal line carries a weight in any karat, a main karat other
    than the one set is refused: 409 main_karat_locked;
  - the one set, sent again, is not a change;
  - before any weighed line -- a new book (the 2027 database, ADR-044) -- it
    is chosen, and changed, freely;
  - the settings say whether it is locked (main_karat_locked), for the screen.

Run:
    python -m pytest tests/test_main_karat_locked.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import Account, AppUser, JournalEntry, JournalEntryLine, Settings, db


@pytest.fixture(autouse=True)
def fenced(app, db_fence, vat_mapped):
    yield


@pytest.fixture
def admin():
    u = AppUser(username=f'admin-{uuid.uuid4().hex[:6]}', role='system_admin', is_active=True, password_hash='x')
    db.session.add(u)
    db.session.flush()
    return u


@pytest.fixture
def row():
    s = Settings.query.order_by(Settings.id).first()
    if s is None:
        s = Settings()
        db.session.add(s)
    s.main_karat = 21
    db.session.flush()
    return s


def _weigh():
    """One line in the books carrying a weight."""
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name='خزينة ذهب', type='Asset', tracks_weight=True)
    b = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name='مقابل', type='Asset', tracks_weight=True)
    db.session.add_all([a, b])
    db.session.flush()
    je = JournalEntry(entry_number=f'MK-{uuid.uuid4().hex[:8]}', date=datetime(2026, 11, 1), description='وزن')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=a.id, debit_21k=1.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=b.id, credit_21k=1.0)])
    db.session.flush()
    return je


def _call(method, user, body=None, path='/api/settings'):
    g.pop('current_user', None)
    client = flask_app.test_client()
    headers = {'Authorization': f'Bearer {generate_token(user)}'}
    if method == 'patch':
        seen = client.get('/api/settings/versions', headers=headers).get_json()['versions']
        body = {'changes': body, 'versions': {k: seen.get(k, 0) for k in body}, 'reason': 'العيار'}
    if method == 'put':
        body = {**body, 'reason': 'العيار'}
    return getattr(client, method)(path, headers=headers, json=body)


def _karat(row):
    db.session.expire_all()
    return db.session.get(Settings, row.id).main_karat


def test_a_line_is_weighed_by_a_weight_in_any_karat_not_by_cash():
    from services.main_karat_lock import weighed
    je = _weigh()
    cash = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name='نقد', type='Asset')
    db.session.add(cash)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=cash.id, cash_debit=50.0))
    db.session.flush()
    mine = JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id == je.id)
    assert mine.count() == 3
    assert mine.filter(weighed()).count() == 2, 'the two gold lines, not the cash one'


def test_before_any_weight_it_is_chosen_freely(row, admin, monkeypatch):
    # A new book has no weighed line; the test database may hold others' -- the
    # branch is the route's, the predicate is tested above.
    monkeypatch.setattr('services.main_karat_lock.locked', lambda: False)
    assert _call('get', admin).get_json()['main_karat_locked'] is False
    resp = _call('patch', admin, {'main_karat': 24})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _karat(row) == 24


@pytest.mark.parametrize('method', ('put', 'patch'))
def test_once_the_books_carry_a_weight_it_is_locked(row, admin, method):
    _weigh()
    assert _call('get', admin).get_json()['main_karat_locked'] is True
    refused = _call(method, admin, {'main_karat': 24})
    assert refused.status_code == 409, refused.get_data(as_text=True)[:300]
    assert refused.get_json()['error'] == 'main_karat_locked'
    assert _karat(row) == 21


def test_the_one_set_sent_again_is_not_a_change(row, admin):
    _weigh()
    resp = _call('put', admin, {'main_karat': 21, 'company_phone': '0566666666'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
