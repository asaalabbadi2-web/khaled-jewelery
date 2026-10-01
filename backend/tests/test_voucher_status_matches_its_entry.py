"""A voucher's status agrees with its entry -- at commit, on every session (V0 decision, ADR-035).

The owner's rule (1 Oct 2026), after the voucher lifecycle was measured
(docs/plans/v0-voucher-lifecycle-map.md):

    approved   -- its entry stands posted
    cancelled  -- its entry stays posted, and a posted reversal stands beside it
    pending    -- no entry
    rejected   -- no entry

So an approved voucher is cancelled, never rejected: rejecting it changed the
status alone and left the posted entry and the safe-box movement counting.
journal_entry_guard holds the rule below any route; the reject route refuses
it first, readably (409).

Run:
    python -m pytest tests/test_voucher_status_matches_its_entry.py -v
"""
import pytest

from app import app as flask_app
from journal_entry_guard import DocumentEntryTouchedAlone
from models import JournalEntry, Voucher, db
from tests.voucher_world import auto_post, create, snapshot, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _refused_at_commit():
    with pytest.raises(DocumentEntryTouchedAlone):
        db.session.commit()
    db.session.rollback()


def _approved(headers, w, shape='cash_receipt'):
    auto_post(True)
    return db.session.get(Voucher, create(headers, w, shape))


def _pending(headers, w, shape='cash_receipt'):
    auto_post(False)
    return db.session.get(Voucher, create(headers, w, shape))


# --- the guard, straight on the session (a maintenance tool, the scheduler) ---

def test_rejecting_an_approved_voucher_on_the_session_is_refused(auth_headers, vworld):
    _approved(auth_headers, vworld).status = 'rejected'
    _refused_at_commit()


def test_an_approved_voucher_whose_entry_is_unposted_is_refused(auth_headers, vworld):
    v = _approved(auth_headers, vworld)
    db.session.get(JournalEntry, v.journal_entry_id).is_posted = False
    _refused_at_commit()


def test_approving_a_voucher_with_no_entry_is_refused(auth_headers, vworld):
    _pending(auth_headers, vworld).status = 'approved'
    _refused_at_commit()


def test_returning_an_approved_voucher_to_pending_with_its_entry_is_refused(auth_headers, vworld):
    _approved(auth_headers, vworld).status = 'pending'
    _refused_at_commit()


def test_cancelling_an_approved_voucher_without_a_reversal_is_refused(auth_headers, vworld):
    _approved(auth_headers, vworld).status = 'cancelled'
    _refused_at_commit()


def test_a_bulk_update_of_voucher_status_is_refused():
    with pytest.raises(DocumentEntryTouchedAlone):
        Voucher.query.filter(Voucher.id < 0).update({'status': 'rejected'}, synchronize_session=False)
    db.session.rollback()


# --- the routes: what passes, what is refused ---

def test_the_reject_route_refuses_an_approved_voucher_and_changes_nothing(auth_headers, vworld):
    v = _approved(auth_headers, vworld)
    before = snapshot(v.id)
    resp = flask_app.test_client().post(f'/api/vouchers/reject/{v.id}', headers=auth_headers,
                                        json={'rejection_reason': 'law'})
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'approved_voucher_is_cancelled_not_rejected'
    assert snapshot(v.id) == before


@pytest.mark.parametrize('shape', ('cash_receipt', 'cash_payment', 'gold_payment'))
def test_the_voucher_operations_leave_status_and_entry_agreeing(auth_headers, vworld, shape):
    """Every sanctioned path commits through the guard: create (approved and
    pending), approve, reject a pending one, cancel an approved and a pending one."""
    c = flask_app.test_client()
    approved = _approved(auth_headers, vworld, shape)
    assert c.post(f'/api/vouchers/{approved.id}/cancel', headers=auth_headers,
                  json={'reason': 'law'}).status_code == 200

    to_approve = _pending(auth_headers, vworld, shape)
    assert c.post(f'/api/vouchers/approve/{to_approve.id}', headers=auth_headers, json={}).status_code == 200
    to_reject = _pending(auth_headers, vworld, shape)
    assert c.post(f'/api/vouchers/reject/{to_reject.id}', headers=auth_headers,
                  json={'rejection_reason': 'law'}).status_code == 200
    to_cancel = _pending(auth_headers, vworld, shape)
    assert c.post(f'/api/vouchers/{to_cancel.id}/cancel', headers=auth_headers,
                  json={'reason': 'law'}).status_code == 200

    db.session.expire_all()
    assert [db.session.get(Voucher, v.id).status for v in (approved, to_approve, to_reject, to_cancel)] == \
        ['cancelled', 'approved', 'rejected', 'cancelled']
