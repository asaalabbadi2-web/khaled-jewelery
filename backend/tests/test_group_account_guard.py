"""An account with accounts under it takes no posting; its own balance moves to one of them (the owner, 18 Nov 2026).

«5440 هذا الحساب مادام له فروع لماذا يظهر في قائمة حسابات السند» -- nine
vouchers of Apr-Sep 2026 (28,222.21) on «5440 رسوم التراخيص ومخالفات» itself,
from a screen that judged a detail account by its number's length; and
«5440000» put under it two days after its first voucher. The owner: «ابدأ
الحارس وتحذير بحيث يمكن اضافة حساب فرعي ونقل الرصيد اليه».
  - no line moves a group's own balance away from zero -- riyals or grams;
    a line bringing it back toward zero is written (a voucher on it undone);
  - putting an account under one with a balance of its own is said, with the
    balance; the account says its own balance;
  - the move: an entry per entry, dated as it, onto the account named under
    the group; a voucher and its reversal left out; once; refused, writing
    nothing, against the balance's side, to an account not under the group,
    or to a group.

Run:
    python -m pytest tests/test_group_account_guard.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from parent_account_guard import GroupAccountPosted
from services.group_balance import MOVED, GroupBalanceRefused, move, own_balance

NOW = dt.datetime(2026, 11, 18, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _account(parent_id=None, kind='Expense'):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:5]}', type=kind,
                parent_id=parent_id, tracks_weight=False, transaction_type='cash')
    db.session.add(a)
    db.session.flush()
    return a


CASH = None


def _entry(on, amount, *, day, reference_type='voucher', reference_id=None):
    """A posted entry: *amount* riyals debited to *on* (credited when negative), the other side cash."""
    global CASH
    if CASH is None or db.session.get(Account, CASH) is None:
        CASH = _account(kind='Asset').id
    je = JournalEntry(entry_number=f'JE-GA-{uuid.uuid4().hex[:6]}', date=dt.datetime(2026, day[0], day[1], 13, 0),
                      description='نقد', entry_type='عادي', is_posted=True, is_draft=False, is_deleted=False,
                      created_by='admin', reference_type=reference_type, reference_id=reference_id)
    db.session.add(je)
    db.session.flush()
    debit, credit = (amount, 0.0) if amount > 0 else (0.0, -amount)
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=on.id, cash_debit=debit, cash_credit=credit),
                        JournalEntryLine(journal_entry_id=je.id, account_id=CASH, cash_debit=credit, cash_credit=debit)])
    db.session.flush()
    return je


def _cash(account):
    rows = JournalEntryLine.query.filter_by(account_id=account.id).filter(JournalEntryLine.is_deleted.isnot(True))
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in rows), 2)


def _licences():
    """«5440» as on production: posted to, then an account put under it."""
    group = _account()
    _entry(group, 345.0, day=(4, 28))
    _entry(group, 1825.0, day=(5, 15))
    child = _account(group.id)
    return group, child


# ── the guard ────────────────────────────────────────────────────────────────

def test_a_group_takes_no_posting_away_from_zero(app):
    group, child = _licences()
    with pytest.raises(GroupAccountPosted) as refused:
        _entry(group, 70.0, day=(8, 4))
    assert group.account_number in refused.value.message
    db.session.rollback()


def test_a_group_with_no_balance_takes_none_either(app):
    group = _account()
    _account(group.id)
    with pytest.raises(GroupAccountPosted):
        _entry(group, -10.0, day=(8, 4))
    db.session.rollback()


def test_back_toward_zero_is_written(app):
    """A voucher on the group undone: its reversal brings the group toward zero."""
    group, child = _licences()
    _entry(group, -345.0, day=(11, 18), reference_type='voucher_reversal')
    assert _cash(group) == 1825.0
    _entry(child, 99.0, day=(11, 18))
    assert _cash(child) == 99.0, 'the account under it takes postings'


# ── the warning, and the balance said ───────────────────────────────────────

def _client_post(path, auth_headers, json):
    g.pop('current_user', None)
    return flask_app.test_client().post(path, headers=auth_headers, json=json)


def test_an_account_put_under_one_with_a_balance_is_warned_of(app, auth_headers):
    group = _account()
    _entry(group, 345.0, day=(4, 28))
    resp = _client_post('/api/accounts', auth_headers, {
        'account_number': f'{group.account_number}1', 'name': 'رسوم تجديد رخص العمل', 'type': 'Expense',
        'parent_id': group.id, 'transaction_type': 'cash'})
    assert resp.status_code == 201, resp.get_json()
    warned = resp.get_json()['parent_own_balance']
    assert (warned['account_id'], warned['cash'], warned['entries']) == (group.id, 345.0, 1)
    g.pop('current_user', None)
    shown = flask_app.test_client().get(f'/api/accounts/{group.id}', headers=auth_headers).get_json()
    assert shown['own_balance']['cash'] == 345.0


def test_an_account_put_under_one_without_a_balance_is_not(app, auth_headers):
    group = _account()
    resp = _client_post('/api/accounts', auth_headers, {
        'account_number': f'{group.account_number}1', 'name': 'فرع', 'type': 'Expense', 'parent_id': group.id,
        'transaction_type': 'cash'})
    assert resp.status_code == 201, resp.get_json()
    assert 'parent_own_balance' not in resp.get_json()


# ── the move ─────────────────────────────────────────────────────────────────

def test_the_move_is_an_entry_per_entry_dated_as_it_once(app):
    group, child = _licences()
    result = move(group.id, child.id, by='owner', now=NOW)
    assert (result['moved'], result['cash']) == (2, 2170.0)
    assert _cash(group) == 0.0 and _cash(child) == 2170.0
    dates = sorted(e.date.date() for e in JournalEntry.query.filter_by(reference_type=MOVED,
                                                                         reference_number=group.account_number))
    assert dates == [dt.date(2026, 4, 28), dt.date(2026, 5, 15)], 'each month keeps its own'
    assert own_balance(group)['any'] is False
    assert move(group.id, child.id, by='owner', now=NOW)['moved'] == 0, 'a second move finds them moved'


def test_a_voucher_and_its_reversal_are_not_moved(app):
    group = _account()
    _entry(group, 345.0, day=(4, 28))
    _entry(group, 2095.0, day=(11, 17), reference_type='voucher', reference_id=987654)
    _entry(group, -2095.0, day=(11, 17), reference_type='voucher_reversal', reference_id=987654)
    child = _account(group.id)
    result = move(group.id, child.id, by='owner', now=NOW)
    assert (result['moved'], result['cash']) == (1, 345.0)
    assert _cash(group) == 0.0


def test_refused_writing_nothing(app):
    group = _account()
    _entry(group, 345.0, day=(4, 28))
    _entry(group, -100.0, day=(5, 1))                  # against the balance, no reversal of anything
    child = _account(group.id)
    grandchild_parent = _account(group.id)
    _account(grandchild_parent.id)
    stranger = _account()
    before = JournalEntry.query.count()
    for to, code in ((child, 'group_balance_mixed'), (stranger, 'not_under_group'),
                     (grandchild_parent, 'target_is_group')):
        with pytest.raises(GroupBalanceRefused) as refused:
            move(group.id, to.id, by='owner', now=NOW)
        assert refused.value.code == code
    assert JournalEntry.query.count() == before


def test_the_route_moves_it(app, auth_headers):
    group, child = _licences()
    resp = _client_post(f'/api/accounts/{group.id}/move-own-balance', auth_headers, {'to_account_id': child.id})
    assert resp.status_code == 200, resp.get_json()
    assert resp.get_json()['moved'] == 2 and _cash(group) == 0.0


# ── through a writer: a voucher on a group says why ─────────────────────────

def test_a_voucher_on_a_group_is_refused_saying_why(app, auth_headers):
    from models import SafeBox, Voucher
    from tests.voucher_world import auto_post
    auto_post(True)
    cash = _account(kind='Asset')
    db.session.add(SafeBox(name=f'صندوق {uuid.uuid4().hex[:5]}', safe_type='cash', account_id=cash.id, is_active=True))
    group = _account(db.session.query(Account.id).filter_by(account_number='52').scalar())
    _account(group.id)
    db.session.flush()
    before = Voucher.query.count()
    resp = _client_post('/api/vouchers', auth_headers, {
        'voucher_type': 'payment', 'date': dt.datetime(2026, 11, 18).isoformat(), 'party_type': 'other',
        'account_lines': [
            {'account_id': group.id, 'line_type': 'debit', 'amount_type': 'cash', 'amount': 70.0},
            {'account_id': cash.id, 'line_type': 'credit', 'amount_type': 'cash', 'amount': 70.0}]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'group_account_posted' and group.account_number in body['message'], body
    db.session.rollback()
    assert Voucher.query.count() == before, 'nothing written'
