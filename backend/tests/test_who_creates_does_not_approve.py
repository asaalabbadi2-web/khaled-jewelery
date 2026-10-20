"""Who creates a voucher or a manual entry does not approve it; the accountant approves within a limit (ADR-036 R4).

The owner's matrix (2 Oct 2026): manual vouchers -- the accountant creates,
the manager approves; manual entries -- the accountant posts another's. And a
limit in amount and weight under which the accountant approves himself, set
in the settings, starting at zero: the accountant approves nothing until the
owner sets it. The system admin (the owner) is not held by the rule.

Found on the way: the creator and the approver were the text the app sent --
`'user'` when it sent none -- and a manual entry recorded no creator at all.
The server now writes both from the session.

Run:
    python -m pytest tests/test_who_creates_does_not_approve.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, JournalEntry, JournalEntryLine, Settings, Voucher, db
from tests.voucher_world import auto_post, payload, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _user(role):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return user, {'Authorization': f'Bearer {generate_token(user)}'}


def _call(method, path, headers, body=None):
    g.pop('current_user', None)   # one app context for the module; each request in production has its own
    return flask_app.test_client().open(path, method=method, headers=headers, json=body or {})


def _limits(cash=0.0, grams=0.0):
    row = Settings.query.first() or Settings()
    row.accountant_approval_limit_cash = cash
    row.accountant_approval_limit_gold_grams = grams
    db.session.add(row)
    db.session.flush()


def _pending_voucher(headers, w, amount=500.0):
    auto_post(False)
    resp = _call('POST', '/api/vouchers', headers, payload(w, 'cash_receipt', amount=amount))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return db.session.get(Voucher, resp.get_json()['id'])


def _approve(voucher_id, headers):
    return _call('POST', f'/api/vouchers/{voucher_id}/approve', headers, {'approved_by': 'someone else'})


def test_the_server_writes_who_created_and_who_approved(vworld):
    accountant, acc_h = _user('accountant')
    manager, man_h = _user('manager')
    body = payload(vworld, 'cash_receipt')
    body['created_by'] = 'not me'
    auto_post(False)
    v = db.session.get(Voucher, _call('POST', '/api/vouchers', acc_h, body).get_json()['id'])
    assert v.created_by == accountant.username
    assert _approve(v.id, man_h).status_code == 200
    db.session.expire_all()
    assert db.session.get(Voucher, v.id).approved_by == manager.username


def test_a_manager_does_not_approve_their_own_voucher(vworld):
    _, man_h = _user('manager')
    v = _pending_voucher(man_h, vworld)
    resp = _approve(v.id, man_h)
    assert resp.status_code == 403 and resp.get_json()['error'] == 'own_document'
    assert _approve(v.id, _user('manager')[1]).status_code == 200


def test_at_a_zero_limit_the_accountant_approves_nothing(vworld):
    _limits(0.0, 0.0)
    v = _pending_voucher(_user('accountant')[1], vworld)
    resp = _approve(v.id, _user('accountant')[1])
    assert resp.status_code == 403 and resp.get_json()['error'] == 'over_approval_limit'


def test_within_the_limit_the_accountant_approves_another_s_voucher(vworld):
    _limits(1000.0, 0.0)
    small = _pending_voucher(_user('accountant')[1], vworld, amount=500.0)
    large = _pending_voucher(_user('accountant')[1], vworld, amount=1500.0)
    approver = _user('accountant')[1]
    assert _approve(small.id, approver).status_code == 200
    assert _approve(large.id, approver).get_json()['error'] == 'over_approval_limit'


def test_auto_approval_at_creation_does_not_approve_the_creator_s_own(vworld):
    auto_post(True)
    resp = _call('POST', '/api/vouchers', _user('accountant')[1], payload(vworld, 'cash_receipt'))
    assert resp.status_code == 201
    assert db.session.get(Voucher, resp.get_json()['id']).status == 'pending'


def test_the_system_admin_is_not_held(vworld, auth_headers):
    auto_post(True)
    resp = _call('POST', '/api/vouchers', auth_headers, payload(vworld, 'cash_receipt'))
    assert db.session.get(Voucher, resp.get_json()['id']).status == 'approved'


def _manual_entry(headers, w):
    body = {'date': datetime(2026, 10, 1).isoformat(), 'description': 'يدوي', 'lines': [
        {'account_id': w['cash'], 'cash_debit': 10.0}, {'account_id': w['gold'], 'cash_credit': 10.0}]}
    resp = _call('POST', '/api/journal_entries', headers, body)
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]
    data = resp.get_json()
    return db.session.get(JournalEntry, (data.get('entry') or data).get('id'))


def test_an_accountant_posts_another_s_manual_entry_not_their_own(vworld):
    """With «ترحيل القيود تلقائيًا» off. On, a manual entry is posted at creation
    whoever creates it -- the owner's decision of 9 Oct 2026, which only the
    system admin turns (tests/test_manual_entry_auto_post.py)."""
    row = Settings.query.first() or Settings()
    row.auto_post_entries = False
    db.session.add(row)
    db.session.flush()
    me, mine_h = _user('accountant')
    entry = _manual_entry(mine_h, vworld)
    assert entry.created_by == me.username and entry.is_posted is False, 'the setting off posted it'
    resp = _call('POST', f'/api/journal-entries/post/{entry.id}', mine_h)
    assert resp.status_code == 403 and resp.get_json()['error'] == 'own_document'
    assert _call('POST', f'/api/journal-entries/post/{entry.id}', _user('accountant')[1]).status_code == 200


def test_the_posting_screen_holds_the_same_rule(vworld):
    _, man_h = _user('manager')
    v = _pending_voucher(man_h, vworld)
    resp = _call('POST', f'/api/vouchers/approve/{v.id}', man_h)
    assert resp.status_code == 403 and resp.get_json()['error'] == 'own_document'
    assert _call('POST', f'/api/vouchers/approve/{v.id}', _user('manager')[1]).status_code == 200


def test_the_settings_carry_the_limit_and_refuse_a_negative(auth_headers):
    resp = _call('PUT', '/api/settings', auth_headers, {'accountant_approval_limit_cash': 2000,
                                                        'accountant_approval_limit_gold_grams': 10})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = _call('GET', '/api/settings', auth_headers).get_json()
    assert (body['accountant_approval_limit_cash'], body['accountant_approval_limit_gold_grams']) == (2000.0, 10.0)
    assert _call('PUT', '/api/settings', auth_headers, {'accountant_approval_limit_cash': -1}).status_code == 400


def test_a_safe_transfer_is_written_by_the_session_not_the_request_text():
    """AV-2026-00506 (the voucher screen review, 20 Oct 2026): a gold transfer
    written by `system` -- the route took its author from the body, `system`
    when none was sent."""
    from models import Account, SafeBox
    user, headers = _user('manager')

    def gold_safe(name):
        acc = Account(account_number=f'7{uuid.uuid4().int % 10**7:07d}', name=name, type='Asset',
                      tracks_weight=True)
        db.session.add(acc)
        db.session.flush()
        box = SafeBox(name=f'{name} {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id,
                      is_active=True, stock_location='showroom')
        db.session.add(box)
        db.session.flush()
        return box

    source, target, other = gold_safe('مصدر'), gold_safe('هدف'), gold_safe('مقابل')
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 9, 1), description='t',
                      is_posted=True)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=source.account_id, debit_21k=5.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=other.account_id, credit_21k=5.0)])
    db.session.flush()
    resp = _call('POST', '/api/safe-boxes/transfer-voucher', headers, {
        'from_safe_box_id': source.id, 'to_safe_box_id': target.id, 'weights': {'21k': 2.0},
        'created_by': 'someone else'})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    voucher = Voucher.query.filter_by(voucher_type='adjustment').order_by(Voucher.id.desc()).first()
    assert (voucher.created_by, voucher.approved_by) == (user.username, user.username)
