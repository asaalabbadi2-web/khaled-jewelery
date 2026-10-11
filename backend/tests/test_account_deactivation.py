"""A deactivated account keeps its history and takes no new entry (ADR-043, phase 1).

The owner (11 Oct 2026, ADR-043): 2210 «ضريبة القيمة المضافة المستحقة» is not
needed -- its balance is zero after stage-4 item 22, its four entries stay --
yet any manual entry, or the mapping's fallback, could still post to it: an
account had no state. Now it has one. A deactivated account:

- stays in the tree, the statements and the reports, with its entries;
- refuses every new line -- the session guard (a readable error, any writer)
  and a database trigger (raw SQL too), as a posted entry is held (ADR-035);
- is refused deactivation while it holds a balance, a line of an entry not
  yet posted, a pending voucher's line, an active child, a mapping, a safe
  box, a customer / supplier / office / employee, or a system setting --
  every way a posting would reach it later.

Run:
    python -m pytest tests/test_account_deactivation.py -v
"""
import uuid
from datetime import datetime

import pytest
import sqlalchemy as sa

from app import app as flask_app
from models import Account, AccountingMapping, JournalEntry, JournalEntryLine, db
from services.account_status import AccountDeactivated, NotDeactivatable, activate_account, deactivate_account

NOW = datetime(2026, 10, 11, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(tag='حساب اختبار', parent=None):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**8}', name=tag, type='Liability',
                parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(lines, posted=True):
    je = JournalEntry(entry_number=f'JE-D-{uuid.uuid4().hex[:8]}', date=datetime(2026, 4, 13),
                      description='اختبار', entry_type='عادي', reference_type='manual',
                      is_posted=posted, is_draft=not posted, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, amount in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='اختبار',
                                        cash_debit=max(amount, 0), cash_credit=max(-amount, 0)))
    db.session.flush()
    return je


@pytest.fixture
def closed():
    """An account like 2210: four movements that net to zero."""
    account, other = _account('ضريبة مستحقة اختبار'), _account('مقابل')
    _entry([(account, 391.30), (other, -391.30)])
    _entry([(account, 2002.18), (other, -2002.18)])
    _entry([(account, -2393.48), (other, 2393.48)])
    return account, other


def test_a_deactivated_account_refuses_a_new_line_from_any_writer(closed):
    account, other = closed
    deactivate_account(account.id, by='t', now=NOW)
    assert db.session.get(Account, account.id).is_active is False
    assert account.to_dict()['is_active'] is False

    with pytest.raises(AccountDeactivated):                       # the application: a readable refusal
        sp = db.session.begin_nested()
        try:
            _entry([(account, 10), (other, -10)])
        finally:
            sp.rollback()

    sp = db.session.begin_nested()                                # raw SQL: the database refuses
    with pytest.raises(sa.exc.DBAPIError) as raised:
        je = JournalEntry(entry_number=f'JE-D-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 1),
                          description='خام', is_posted=True)
        db.session.add(je)
        db.session.flush()
        db.session.execute(sa.text('INSERT INTO journal_entry_line (journal_entry_id, account_id, cash_debit, '
                                   'cash_credit) VALUES (:j, :a, 5, 0)'), {'j': je.id, 'a': account.id})
    sp.rollback()
    assert 'deactivated' in str(raised.value.orig)


def test_its_history_stays_and_can_still_be_corrected(closed):
    """The entries already on it stay, and a line on it may be soft-deleted --
    only a NEW line, or a line moved onto it, is refused."""
    account, other = closed
    deactivate_account(account.id, by='t', now=NOW)
    lines = JournalEntryLine.query.filter_by(account_id=account.id).all()
    assert len(lines) == 3
    lines[0].is_deleted = True
    db.session.flush()

    sp = db.session.begin_nested()
    with pytest.raises((AccountDeactivated, sa.exc.DBAPIError)):
        moved = JournalEntryLine.query.filter_by(account_id=other.id).first()
        moved.account_id = account.id
        db.session.flush()
    sp.rollback()


def test_activated_again_it_takes_entries(closed):
    account, other = closed
    deactivate_account(account.id, by='t', now=NOW)
    activate_account(account.id, by='t', now=NOW)
    _entry([(account, 10), (other, -10)])


@pytest.mark.parametrize('why', ['balance', 'draft', 'child', 'mapping'])
def test_what_a_posting_would_reach_is_not_deactivated(why):
    account, other = _account(), _account('مقابل')
    if why == 'balance':
        _entry([(account, 50), (other, -50)])
    elif why == 'draft':
        _entry([(account, 50), (other, -50)], posted=False)
        _entry([(account, -50), (other, 50)])
    elif why == 'child':
        _account('ابن نشط', parent=account)
    elif why == 'mapping':
        db.session.add(AccountingMapping(operation_type='اختبار', account_type='vat_payable', account_id=account.id,
                                         is_active=True))
        db.session.flush()
    with pytest.raises(NotDeactivatable) as refused:
        deactivate_account(account.id, by='t', now=NOW)
    assert refused.value.code
    assert db.session.get(Account, account.id).is_active is True


def test_the_routes(closed, auth_headers):
    account, _ = closed
    client = flask_app.test_client()
    r = client.post(f'/api/accounts/{account.id}/deactivate', headers=auth_headers)
    assert r.status_code == 200 and r.get_json()['is_active'] is False
    busy = _account()
    _entry([(busy, 5), (_account('مقابل'), -5)])
    r = client.post(f'/api/accounts/{busy.id}/deactivate', headers=auth_headers)
    assert r.status_code == 409 and r.get_json()['error'] == 'HAS_BALANCE'
    r = client.post(f'/api/accounts/{account.id}/activate', headers=auth_headers)
    assert r.status_code == 200 and r.get_json()['is_active'] is True
