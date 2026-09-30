"""The one unposting of an invoice (UNPOST-001 U1, ADR-034): its laws.

posting_routes.unpost_invoice_document is the counterpart of
post_invoice_document, and the three unpost routes -- the posting screen, its
batch, the invoices route -- all call it. U0 measured them disagreeing
(docs/plans/unpost-001-u0-retraction-map.md).

Laws:
  - the three routes leave the books in the same state;
  - post, unpost, post brings the ledger and the inventory back where they were;
  - it completes or is refused whole: a failure halfway changes nothing;
  - an 'unpost' audit row marks success, and only success.

Witnessed, not yet law: the round trip in the SAFES for a sale. Posting at
creation (add_invoice) and posting later (post_invoice_document) are two
writers that disagree -- on a restored copy (1 Oct 2026) a re-posted sale moved
twice its gold out of the display box when a line had a quantity above one, and
a supplier purchase gained a safe row creation never wrote. That is
SAFEBOX-001's to close, not the unposting's.

Run:
    python -m pytest tests/test_unpost_001_u1_laws.py -v
"""
import pytest

from app import app as flask_app
from models import AuditLog, db
from tests.books_snapshot import diff, snapshot
from tests.retraction_world import _create, unposting_allowed, world  # noqa: F401 (fixtures)

ROUTES = {
    'posting_screen': lambda c, h, i: c.post(f'/api/invoices/unpost/{i}', headers=h, json={}),
    'invoices_route': lambda c, h, i: c.post(f'/api/invoices/{i}/unpost', headers=h, json={}),
    'batch': lambda c, h, i: c.post('/api/invoices/unpost-batch', headers=h, json={'invoice_ids': [i]}),
}
UNPOSTABLE = ('scrap_purchase_unpaid', 'sale_on_credit')


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _key(inv):
    return inv['invoice_type'], inv['invoice_type_id'], (inv['id'],)


def _without_audit(snap):
    return {k: v for k, v in snap.items() if k != 'audit_log'}


def _post(headers, invoice_id):
    return flask_app.test_client().post(f'/api/invoices/post/{invoice_id}', headers=headers, json={})


@pytest.mark.parametrize('shape', UNPOSTABLE)
def test_the_three_routes_leave_the_same_books(auth_headers, unposting_allowed, world, shape):
    results = {}
    for name, route in ROUTES.items():
        inv = _create(auth_headers, world, shape, held=False)
        resp = route(flask_app.test_client(), auth_headers, inv['id'])
        assert resp.status_code == 200, (name, resp.get_data(as_text=True)[:200])
        results[name] = snapshot(*_key(inv))
    first = results['posting_screen']
    for name, snap in results.items():
        assert snap == first, f'{name} differs from the posting screen: {diff(first, snap)}'


def _ledger_and_inventory(snap):
    return {k: v for k, v in snap.items()
            if k.startswith('invoice_entries.posted.') or k == 'inventory_ledger.net' or k == 'invoice.is_posted'}


def _safes(snap):
    """Each safe-box row kind collapsed to its weight and cash -- the name is SAFEBOX-001's."""
    out = {}
    for k, v in snap.items():
        if k.startswith('sbt.') and not k.endswith('.rows'):
            dim = k.rsplit('.', 1)[1]
            out[dim] = round(out.get(dim, 0.0) + v, 4)
    return {k: v for k, v in out.items() if v}


@pytest.mark.parametrize('route', sorted(ROUTES))
@pytest.mark.parametrize('shape', UNPOSTABLE)
def test_a_round_trip_brings_the_ledger_and_the_inventory_back(auth_headers, unposting_allowed, world, shape, route):
    inv = _create(auth_headers, world, shape, held=False)
    posted = snapshot(*_key(inv))
    assert ROUTES[route](flask_app.test_client(), auth_headers, inv['id']).status_code == 200
    assert _post(auth_headers, inv['id']).status_code == 200
    assert _ledger_and_inventory(snapshot(*_key(inv))) == _ledger_and_inventory(posted)


@pytest.mark.parametrize('shape', [
    'scrap_purchase_unpaid',
    pytest.param('sale_on_credit', marks=pytest.mark.xfail(
        strict=True, reason='SAFEBOX-001: posting at creation and posting later are two writers')),
])
def test_a_round_trip_brings_the_safes_back(auth_headers, unposting_allowed, world, shape):
    inv = _create(auth_headers, world, shape, held=False)
    posted = snapshot(*_key(inv))
    assert ROUTES['invoices_route'](flask_app.test_client(), auth_headers, inv['id']).status_code == 200
    assert _post(auth_headers, inv['id']).status_code == 200
    assert _safes(snapshot(*_key(inv))) == _safes(posted)


@pytest.mark.parametrize('route', sorted(ROUTES))
def test_a_failure_halfway_changes_nothing(auth_headers, unposting_allowed, world, route, monkeypatch):
    inv = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    posted = snapshot(*_key(inv))

    from services.inventory_posting_service import InventoryPostingService

    def boom(*a, **kw):
        raise RuntimeError('halfway')
    monkeypatch.setattr(InventoryPostingService, 'reverse', classmethod(boom))
    resp = ROUTES[route](flask_app.test_client(), auth_headers, inv['id'])
    assert resp.status_code >= 400
    assert _without_audit(snapshot(*_key(inv))) == _without_audit(posted)


@pytest.mark.parametrize('route', sorted(ROUTES))
def test_an_unpost_audit_row_marks_success_only(auth_headers, unposting_allowed, world, route):
    refused = _create(auth_headers, world, 'scrap_purchase_paid', held=False)   # a payment stands
    assert ROUTES[route](flask_app.test_client(), auth_headers, refused['id']).status_code == 409
    done = _create(auth_headers, world, 'scrap_purchase_unpaid', held=False)
    assert ROUTES[route](flask_app.test_client(), auth_headers, done['id']).status_code == 200

    def ok_rows(invoice_id):
        return AuditLog.query.filter(AuditLog.entity_type.in_(('invoice', 'Invoice')), AuditLog.entity_id == invoice_id,
                                     AuditLog.action == 'unpost', AuditLog.success.is_(True)).count()
    db.session.expire_all()
    assert ok_rows(refused['id']) == 0
    assert ok_rows(done['id']) == 1
