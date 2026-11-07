"""«رفض العدّ»: a closed count goes back to counting (the owner, 8 Nov 2026: option أ).

A closed count could only be approved: a count with a wrong line held its
location (no new session while it waits) and left the books only through a
wrong differences entry. Now its approver (inventory.approve) sends it back,
with a reason: it is «قيد العدّ» again, its lines keep their counts, the
counter corrects what is wrong and closes again. Who, when, why and every
line's count as it stood are kept: once closed, a blind count's books were
shown, so the approver sees what changed after the return. No entry written.

Run:
    python -m pytest tests/test_count_return.py -v
"""
import uuid

import pytest

from auth_decorators import generate_token
from app import app as flask_app
from models import InventoryCountReturn, JournalEntry, Permission, Role, User, db
from tests.test_stock_count import NOW, _category, _safe, _stock, roles  # noqa: F401 -- the fixture


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _signed_out():
    """One app context for the module: each request signs in afresh."""
    from flask import g
    g.pop('current_user', None)


def _headers_for(*codes):
    _signed_out()
    suffix = uuid.uuid4().hex[:8]
    user = User(username=f'cr_{suffix}', full_name='count', is_active=True, is_admin=False)
    user.set_password('x')
    db.session.add(user)
    db.session.flush()
    role = Role(name=f'cr_role_{suffix}', name_ar='دور اختبار', is_active=True)
    db.session.add(role)
    db.session.flush()
    for code in codes:
        perm = Permission.query.filter_by(code=code).first()
        if perm is None:
            perm = Permission(code=code, name=code, name_ar=code, category='inventory', is_active=True)
            db.session.add(perm)
            db.session.flush()
        role.permissions.append(perm)
    user.roles.append(role)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _closed(grams_counted=18.0):
    """A location holding 20 g of 21k rings, counted (wrongly) and closed."""
    from services.inventory_count_service import InventoryCountService as S
    box, ring = _safe(), _category()
    _stock(box, 20.0, ring)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    S.record_count(session, category_id=ring.id, karat=21.0, counted_weight=grams_counted, counted_by='t',
                   now=NOW, safe_box_id=box.id)
    S.close_session(session, now=NOW)
    return session, box, ring


def test_a_closed_count_goes_back_to_counting_its_counts_kept(app):
    from services.inventory_count_service import InventoryCountService as S
    session, _, _ = _closed()
    entries = JournalEntry.query.count()
    S.return_session(session, returned_by='المالك', reason='الخواتم لم تُعدّ كلها', now=NOW)
    assert session.status == 'counting' and session.closed_at is None
    assert [l.counted_weight for l in session.lines] == [18.0], 'its lines keep their counts'
    r = InventoryCountReturn.query.filter_by(session_id=session.id).one()
    assert (r.returned_by, r.reason) == ('المالك', 'الخواتم لم تُعدّ كلها')
    assert list(r.counts.values()) == [18.0]
    assert JournalEntry.query.count() == entries, 'no entry'


def test_returned_it_is_counted_again_closed_and_approved_as_counted(app, roles):
    from services.inventory_count_service import InventoryCountService as S
    session, box, ring = _closed()
    S.return_session(session, returned_by='المالك', reason='أعد عدّ الخواتم', now=NOW)
    S.record_count(session, category_id=ring.id, karat=21.0, counted_weight=20.0, counted_by='t', now=NOW,
                   safe_box_id=box.id)
    S.close_session(session, now=NOW)
    _, entry = S.approve_session(session, approved_by='المالك', now=NOW)
    assert entry is None, 'counted as held: nothing differs'


def test_only_a_closed_count_is_returned_and_never_without_a_reason(app):
    from services.inventory_count_service import InventoryCountService as S
    session, _, _ = _closed()
    with pytest.raises(ValueError, match='سبب الرفض مطلوب'):
        S.return_session(session, returned_by='المالك', reason='  ', now=NOW)
    S.return_session(session, returned_by='المالك', reason='خطأ', now=NOW)
    with pytest.raises(ValueError, match='لا يُرفض إلا عدٌّ مغلق'):
        S.return_session(session, returned_by='المالك', reason='مرة أخرى', now=NOW)


def test_the_approver_returns_it_the_counter_cannot(app):
    session, _, _ = _closed()
    client = flask_app.test_client()
    url = f'/api/inventory/count/{session.id}/return'
    counter = _headers_for('inventory.view', 'inventory.count')
    assert client.post(url, json={'reason': 'خطأ'}, headers=counter).status_code == 403
    approver = _headers_for('inventory.approve')
    assert client.post(url, json={}, headers=approver).status_code == 400
    _signed_out()
    resp = client.post(url, json={'reason': 'الخواتم لم تُعدّ كلها'}, headers=approver)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['status'] == 'counting'
    assert [r['reason'] for r in body['returns']] == ['الخواتم لم تُعدّ كلها']
    assert [l['count_before_return'] for l in body['lines']] == [18.0]
    assert [l['expected_weight'] for l in body['lines']] == [None], 'blind again while counting'
