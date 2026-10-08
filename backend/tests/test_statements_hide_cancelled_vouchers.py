"""A statement hides cancelled vouchers and their reversals by default, and shows them on request (the owner, 9 Oct 2026).

«إخفاء السندات الملغاة وقيودها العكسية ... ينحصر الإخفاء في شاشة العرض والطباعة
فقط دون حذفها من قاعدة البيانات» -- hidden by default, a button shows them.

The laws (services/cancelled_vouchers.py):
  - hiding never moves a balance: the closing balance and the net of the totals
    are the same hidden or shown;
  - a pair is hidden whole: the voucher's entry and its reversal, or neither;
  - a pair the statement does not hold whole (a period that cuts it), or that
    does not net to zero on its lines, is shown;
  - what is hidden is said: how many, which vouchers.

Run:
    python -m pytest tests/test_statements_hide_cancelled_vouchers.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, Customer, JournalEntry, JournalEntryLine, Supplier, Voucher, db
from services.cancelled_vouchers import without_cancelled_pairs


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:8]


def _entry(account, other, amount, *, day, ref_type='voucher', ref_id=None):
    je = JournalEntry(entry_number=f'T-{_uid()}', date=datetime(2026, 10, day), description='t',
                      entry_type='عادي', reference_type=ref_type, reference_id=ref_id,
                      is_posted=True, is_draft=False)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id,
                         cash_debit=max(amount, 0.0), cash_credit=max(-amount, 0.0)),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id,
                         cash_debit=max(-amount, 0.0), cash_credit=max(amount, 0.0)),
    ])
    db.session.flush()
    return je


def _voucher(entry, status):
    v = Voucher(voucher_number=f'RV-T-{_uid()}', voucher_type='receipt', date=entry.date, status=status,
                amount_cash=100.0, journal_entry_id=entry.id)
    db.session.add(v)
    db.session.flush()
    entry.reference_id = v.id
    db.session.flush()
    return v


@pytest.fixture
def books():
    """One account: a live voucher of 500, and a voucher of 300 cancelled and reversed."""
    account = Account(account_number=f'9{_uid()[:6]}', name='حساب كشف', type='Asset')
    other = Account(account_number=f'8{_uid()[:6]}', name='مقابل', type='Asset')
    db.session.add_all([account, other])
    db.session.flush()
    live = _voucher(_entry(account, other, 500.0, day=1), 'approved')
    original = _entry(account, other, 300.0, day=2)
    cancelled = _voucher(original, 'cancelled')
    reversal = _entry(account, other, -300.0, day=3, ref_type='voucher_reversal', ref_id=cancelled.id)
    return {'account': account, 'other': other, 'live': live, 'cancelled': cancelled,
            'original': original, 'reversal': reversal}


def _statement(headers, account, **params):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(f'/api/accounts/{account.id}/statement', headers=headers,
                                       query_string={'separate': 1, **params})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_by_default_the_pair_is_hidden_and_said(auth_headers, books):
    body = _statement(auth_headers, books['account'])
    entries = {line['journal_entry_id'] for line in body['lines']}
    assert books['original'].id not in entries and books['reversal'].id not in entries
    assert books['live'].journal_entry_id in entries
    assert body['cancelled_hidden'] == {'count': 1, 'vouchers': [books['cancelled'].voucher_number],
                                        'hidden': True}


def test_on_request_it_is_shown(auth_headers, books):
    body = _statement(auth_headers, books['account'], include_cancelled=1)
    entries = {line['journal_entry_id'] for line in body['lines']}
    assert {books['original'].id, books['reversal'].id} <= entries
    assert body['cancelled_hidden']['count'] == 1 and body['cancelled_hidden']['hidden'] is False


def test_hiding_never_moves_a_balance(auth_headers, books):
    hidden = _statement(auth_headers, books['account'])
    shown = _statement(auth_headers, books['account'], include_cancelled=1)
    assert hidden['closing_balance_cash'] == shown['closing_balance_cash'] == 500.0
    net = lambda b: round(b['totals']['cash_debit'] - b['totals']['cash_credit'], 2)   # noqa: E731
    assert net(hidden) == net(shown)


def test_a_pair_cut_by_the_statement_is_shown(books):
    """The statement holds the cancelled voucher's entry but not its reversal
    (a period ending between them): both stay, or the closing balance lies."""
    lines = JournalEntryLine.query.filter(JournalEntryLine.account_id == books['account'].id,
                                          JournalEntryLine.journal_entry_id != books['reversal'].id).all()
    kept, summary = without_cancelled_pairs(lines, include=False)
    assert kept == lines and summary['count'] == 0


def test_a_pair_that_does_not_net_to_zero_is_shown(books):
    line = JournalEntryLine.query.filter_by(journal_entry_id=books['reversal'].id,
                                            account_id=books['account'].id).one()
    line.cash_credit = 250.0          # a reversal that does not undo the whole voucher
    db.session.flush()
    lines = JournalEntryLine.query.filter_by(account_id=books['account'].id).all()
    kept, summary = without_cancelled_pairs(lines, include=False)
    assert kept == lines and summary['count'] == 0


def test_a_cancelled_voucher_with_no_posted_reversal_is_shown(books):
    lines = JournalEntryLine.query.filter(JournalEntryLine.account_id == books['account'].id,
                                          JournalEntryLine.journal_entry_id != books['reversal'].id).all()
    books['reversal'].is_posted = False     # its reversal does not count in the books
    db.session.flush()
    kept, summary = without_cancelled_pairs(lines, include=False)
    assert kept == lines and summary['count'] == 0


@pytest.mark.parametrize('route', ['customers', 'suppliers'])
def test_the_party_statements_say_what_they_hide(auth_headers, route):
    party = (Customer if route == 'customers' else Supplier).query.first()
    if party is None:
        pytest.skip(f'no {route} in the test database')
    g.pop('current_user', None)
    for params in ({}, {'include_cancelled': 1}):
        resp = flask_app.test_client().get(f'/api/{route}/{party.id}/statement', headers=auth_headers,
                                           query_string=params)
        assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
        assert set(resp.get_json()['cancelled_hidden']) == {'count', 'vouchers', 'hidden'}
