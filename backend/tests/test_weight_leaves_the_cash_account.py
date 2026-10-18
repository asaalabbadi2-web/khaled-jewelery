"""A weight on a cash account goes to its weight twin, even with the twin in the entry (17 Oct 2026).

The owner's design: the screen shows a party's cash and weight accounts as one;
the server keeps them apart -- grams to the weight twin, riyals to the cash one
(dual_distribution_service). It stood aside when the twin was already in the
entry («the user sent both sides explicitly»). The calibration JE-2026-06478
(12 Oct, «معايرة ذهب عيار ١٨ الى عيار ٢١») sent 1,956.7 g of 18k off the twin
72100001 and 1,677.171 g of 21k onto the cash account 2100001 -- so the 21k
stayed on the cash account, and the twin read as the safe «حسابنا بشركة الجنيه
العربي» showed -1,677 g the owner does not hold. A cash account carries no
grams: there is no explicit choice to keep. With no twin to take them, the
manual entry is refused by name.

Run:
    python -m pytest tests/test_weight_leaves_the_cash_account.py -v
"""
import uuid

import pytest
from flask import g

from account_pair_service import link_accounts
from app import app as flask_app
from models import Account, JournalEntryLine, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(weight, number=None):
    a = Account(account_number=number or f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:5]}',
                type='Liability', transaction_type='gold' if weight else 'cash', tracks_weight=weight)
    db.session.add(a)
    db.session.flush()
    return a


def _pair():
    cash, gold = _account(False), _account(True)
    link_accounts(cash, gold, created_by='test')
    db.session.flush()
    return cash, gold


def _call(method, path, headers, body):
    g.pop('current_user', None)
    return getattr(flask_app.test_client(), method)(path, headers=headers, json=body)


def _lines(je_id):
    db.session.expire_all()
    out = {}
    for ln in JournalEntryLine.query.filter_by(journal_entry_id=je_id).all():
        row = out.setdefault(ln.account_id, {'18k': 0.0, '21k': 0.0})
        row['18k'] += float(ln.debit_18k or 0) - float(ln.credit_18k or 0)
        row['21k'] += float(ln.debit_21k or 0) - float(ln.credit_21k or 0)
    return out


def _calibration(cash, gold):
    return {'description': 'معايرة ذهب عيار ١٨ الى عيار ٢١', 'date': '2026-10-12T10:00:00', 'is_draft': True,
            'lines': [{'account_id': gold.id, 'credit_18k': 1956.7},
                      {'account_id': cash.id, 'debit_21k': 1677.171}]}


def test_the_calibration_puts_its_21k_on_the_twin_not_the_cash_account(auth_headers):
    cash, gold = _pair()
    resp = _call('post', '/api/journal_entries', auth_headers, _calibration(cash, gold))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]

    lines = _lines(resp.get_json()['id'])
    assert lines.get(cash.id, {'18k': 0.0, '21k': 0.0}) == {'18k': 0.0, '21k': 0.0}
    assert lines[gold.id] == {'18k': pytest.approx(-1956.7), '21k': pytest.approx(1677.171)}


def test_editing_an_entry_routes_the_same(auth_headers):
    cash, gold = _pair()
    created = _call('post', '/api/journal_entries', auth_headers, {
        'description': 'قيد', 'date': '2026-10-12T10:00:00', 'is_draft': True,
        'lines': [{'account_id': gold.id, 'debit_21k': 1.0}, {'account_id': gold.id, 'credit_21k': 1.0}]})
    assert created.status_code == 201, created.get_data(as_text=True)[:300]
    je_id = created.get_json()['id']

    resp = _call('put', f'/api/journal_entries/{je_id}', auth_headers, _calibration(cash, gold))
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    lines = _lines(je_id)
    assert lines.get(cash.id, {'18k': 0.0, '21k': 0.0})['21k'] == 0.0
    assert lines[gold.id]['21k'] == pytest.approx(1677.171)


def test_grams_on_a_cash_account_with_no_twin_are_refused_by_name(auth_headers):
    lone_cash, gold = _account(False), _account(True)
    resp = _call('post', '/api/journal_entries', auth_headers, {
        'description': 'قيد', 'date': '2026-10-12T10:00:00', 'is_draft': True,
        'lines': [{'account_id': lone_cash.id, 'debit_21k': 5.0}, {'account_id': gold.id, 'credit_21k': 5.0}]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['code'] == 'weight_on_cash_account'
    assert lone_cash.account_number in resp.get_json()['error']
