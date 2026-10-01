"""U4's voucher paths: no unapproval, and every approval names its voucher (owner, 1 Oct 2026).

  - unapprove is gone. V0 measured it: it refused any voucher with an entry,
    and every approved voucher has one -- it never ran after approval. Keeping
    it suggested a state change that does not exist. An approved voucher is
    cancelled (a posted reversal; its history stays).
  - the batch approval writes each voucher's own audit row, as the single
    approval does; its one batch row named no voucher.

Run:
    python -m pytest tests/test_u4_voucher_paths.py -v
"""
import pytest

from app import app as flask_app
from models import AuditLog, Voucher, db
from tests.voucher_world import auto_post, create, vworld  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_no_route_returns_an_approved_voucher_to_pending():
    rules = [r.rule for r in flask_app.url_map.iter_rules() if 'unapprove' in r.rule and 'voucher' in r.rule]
    assert rules == [], rules


def test_the_batch_approval_writes_each_vouchers_audit_row(auth_headers, vworld):
    auto_post(False)
    ids = [create(auth_headers, vworld, shape) for shape in ('cash_receipt', 'cash_payment')]
    resp = flask_app.test_client().post('/api/vouchers/approve/batch', headers=auth_headers,
                                        json={'voucher_ids': ids})
    assert resp.get_json()['approved_count'] == 2, resp.get_data(as_text=True)[:300]
    db.session.expire_all()
    for vid in ids:
        assert db.session.get(Voucher, vid).status == 'approved'
        rows = AuditLog.query.filter_by(entity_type='voucher', entity_id=vid, action='voucher_approve').all()
        assert [r.success for r in rows] == [True], vid
