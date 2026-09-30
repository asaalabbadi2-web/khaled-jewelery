"""An unposted invoice has no financial effect anywhere, cash or gold (ADR-034).

The owner's decision (1 Oct 2026): posting is where a document's financial
effect enters the books. Held for approval or unposted, its entries are drafts,
no safe-box row stands for it, and the inventory ledger does not count it.
Unposting reverses what posting wrote, whatever it wrote -- gold as cash, no
rule of its own for scrap.

Measured in U0 (docs/plans/unpost-001-u0-retraction-map.md): a held invoice's
entries are unposted but not drafts; after an unpost, on every path, the
entries are not drafts and the inventory-ledger row stays unreversed; the posting screen
and the batch also keep the scrap gold in the custody safe.

Proved in UNPOST-001 U1: one unposting for the three routes
(posting_routes.unpost_invoice_document), drafts at creation for an invoice
left unposted, and the creation-time safe-box rows gated on posting now --
not only on approval, which left them written when auto-post was off.

Run:
    python -m pytest tests/test_adr034_unposted_has_no_financial_effect.py -v
"""
import pytest

from app import app as flask_app
from models import InventoryLedger, JournalEntry, SafeBoxTransaction, db
from tests.retraction_world import _create, unposting_allowed, world  # noqa: F401 (fixtures)

UNPOST = {
    'posting_screen': lambda c, h, i: c.post(f'/api/invoices/unpost/{i}', headers=h, json={}),
    'invoices_route': lambda c, h, i: c.post(f'/api/invoices/{i}/unpost', headers=h, json={}),
    'batch': lambda c, h, i: c.post('/api/invoices/unpost-batch', headers=h, json={'invoice_ids': [i]}),
}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _effects(invoice_id):
    """What of the invoice still counts: non-draft entries, safe-box rows, and its
    net in the inventory ledger -- an append-only log (ADR-002): unposting
    reverses it with rows of its own, so its NET is what must be zero."""
    db.session.expire_all()
    entries = JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id).all()
    return {
        'entries_not_draft': sum(1 for e in entries if not e.is_draft),
        'safe_box_rows': SafeBoxTransaction.query.filter_by(invoice_id=invoice_id).count(),
        'inventory_ledger_net': round(sum(r.weight_delta or 0.0 for r in InventoryLedger.query.filter_by(
            source_type='invoice', source_id=invoice_id).all()), 6),
    }


NONE = {'entries_not_draft': 0, 'safe_box_rows': 0, 'inventory_ledger_net': 0.0}


@pytest.mark.parametrize('shape', ('scrap_purchase_unpaid', 'scrap_purchase_paid', 'sale_on_credit'))
def test_a_held_invoice_counts_nowhere(auth_headers, world, shape):
    inv = _create(auth_headers, world, shape, held=True)
    assert _effects(inv['id']) == NONE


@pytest.mark.parametrize('path', sorted(UNPOST))
@pytest.mark.parametrize('shape', ('scrap_purchase_unpaid', 'sale_on_credit'))
def test_an_unposted_invoice_counts_nowhere(auth_headers, unposting_allowed, world, shape, path):
    inv = _create(auth_headers, world, shape, held=False)
    resp = UNPOST[path](flask_app.test_client(), auth_headers, inv['id'])
    assert resp.status_code == 200, resp.get_data(as_text=True)[:200]
    assert _effects(inv['id']) == NONE
