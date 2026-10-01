"""A bonus voucher is born approved, so its entry is born posted (V0 decision, owner 1 Oct 2026).

The bonus approval, payment and reversal write their voucher 'approved'
outright. Its entry used to be posted only when the auto-post settings were on
-- production's setting, so production's 17 bonus vouchers agree -- and was a
draft otherwise: an approved voucher with a draft entry, which the voucher rule
(journal_entry_guard) refuses. The owner's decision: the entry is posted in the
same operation whatever the settings say, and a failure to make it fails the
whole operation -- never an approved voucher without one.

Run:
    python -m pytest tests/test_bonus_voucher_is_born_posted.py -v
"""
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, Employee, EmployeeBonus, JournalEntry, SafeBox, Settings, Voucher, db
from tests.voucher_world import create, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def auto_post_off():
    """The world where the old paths left the entry a draft."""
    row = Settings.query.first() or Settings()
    row.voucher_auto_post = False
    row.auto_post_entries = False
    db.session.add(row)
    for number, name, kind in (('5401', 'مصروف مكافآت الموظفين', 'Expense'),
                               ('2310', 'مكافآت مستحقة للموظفين', 'Liability')):
        if not Account.query.filter_by(account_number=number).first():
            db.session.add(Account(account_number=number, name=name, type=kind, tracks_weight=False))
    db.session.flush()


def _bonus(status):
    b = EmployeeBonus(employee_id=Employee.query.first().id, bonus_type='fixed', amount=500.0, status=status,
                      period_start=date(2026, 7, 1), period_end=date(2026, 7, 31), created_at=datetime.now(),
                      **({'approved_by': 't', 'approved_at': datetime.now()} if status == 'approved' else {}))
    db.session.add(b)
    db.session.flush()
    return b.id


def _born_posted(voucher_number):
    db.session.expire_all()
    v = Voucher.query.filter_by(voucher_number=voucher_number).one()
    je = db.session.get(JournalEntry, v.journal_entry_id) if v.journal_entry_id else None
    assert (v.status, je is not None and bool(je.is_posted)) == ('approved', True), voucher_number


def test_the_approval_voucher_is_born_posted(auto_post_off):
    from bonus_routes import _approve_single_bonus
    bonus_id = _bonus('pending')
    ok, payload = _approve_single_bonus(bonus_id, 'admin')
    assert ok, payload
    _born_posted(f'BAPP-{bonus_id}')


def test_the_reversal_voucher_is_born_posted(auto_post_off):
    from bonus_reversal_service import BonusReversalService
    ok, payload = BonusReversalService.reverse(_bonus('approved'), 'admin')
    assert ok, payload
    _born_posted(payload['voucher_number'])


def test_the_payment_voucher_is_born_posted(auth_headers, auto_post_off, vworld):
    create(auth_headers, vworld, 'cash_receipt')     # pending: no entry yet, so no cash
    receipt = Voucher.query.order_by(Voucher.id.desc()).first()
    assert flask_app.test_client().post(f'/api/vouchers/approve/{receipt.id}', headers=auth_headers,
                                        json={}).status_code == 200   # 500 in the safe to pay from
    bonus_id = _bonus('approved')
    safe = SafeBox.query.filter_by(account_id=vworld['cash']).one()
    resp = flask_app.test_client().post(f'/api/bonuses/{bonus_id}/pay', headers=auth_headers,
                                        json={'safe_box_id': safe.id, 'payment_method': 'cash'})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    v = Voucher.query.filter_by(reference_type='bonus', reference_id=bonus_id, voucher_type='payment').one()
    _born_posted(v.voucher_number)


def test_no_entry_fails_the_whole_approval(auto_post_off, monkeypatch):
    import accounting.voucher_engine as engine
    from bonus_routes import _approve_single_bonus
    monkeypatch.setattr(engine, 'create_journal_entry_from_voucher', lambda voucher: None)
    bonus_id = _bonus('pending')
    db.session.commit()      # the bonus stands; only the approval may be undone
    ok, _ = _approve_single_bonus(bonus_id, 'admin')
    assert not ok
    db.session.expire_all()
    assert Voucher.query.filter_by(voucher_number=f'BAPP-{bonus_id}').first() is None
    assert db.session.get(EmployeeBonus, bonus_id).status == 'pending'
