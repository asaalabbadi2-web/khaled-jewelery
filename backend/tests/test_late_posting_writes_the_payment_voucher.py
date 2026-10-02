"""A paid invoice posted later gets its payment voucher, as one posted at creation does (LINK-001, the owner 2 Oct 2026).

Posted as it is saved, an invoice's payment gets a voucher: approved, naming
the invoice, linked to its payment row (source_voucher_id), its entry the one
that carries the payment. Held for approval (a scrap purchase above the live
price) and posted later, the same payment got its entry lines and its safe
rows -- and no voucher: two writers of one fact. On the 2 Oct copy 55 scrap
purchases have no payment voucher, four of them since August (3202 on 1 Oct).
The books are the same either way; the voucher -- the document, its number,
the vouchers list -- is what was missing.

The law: posting later writes the payment voucher posting at creation writes,
once (posting again writes no second one).

Run:
    python -m pytest tests/test_late_posting_writes_the_payment_voucher.py -v
"""
import pytest

from app import app as flask_app
from models import InvoicePayment, JournalEntry, Voucher, db
from tests.retraction_world import _create, unposting_allowed, world  # noqa: F401 (fixtures)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _payment_vouchers(invoice_id):
    return Voucher.query.filter_by(reference_type='invoice', reference_id=invoice_id).all()


def _shape(invoice_id):
    """What a payment voucher says, the parts both writers must agree on."""
    out = []
    for v in _payment_vouchers(invoice_id):
        payment = InvoicePayment.query.filter_by(source_voucher_id=v.id).one()
        entry = db.session.get(JournalEntry, v.journal_entry_id)
        amount = round(float(payment.amount), 2)
        assert round(float(v.amount_cash), 2) == amount, 'the voucher is its payment\'s amount'
        lines = sorted((l.line_type, l.amount_type, round(float(l.amount), 2) == amount) for l in v.account_lines.all())
        out.append((v.voucher_type, v.status, v.party_type, bool(entry and entry.is_posted), tuple(lines)))
    return sorted(out)


def test_a_held_paid_purchase_posted_later_gets_its_payment_voucher(auth_headers, world):
    held = _create(auth_headers, world, 'scrap_purchase_paid', held=True)
    assert _payment_vouchers(held['id']) == [], 'held: no voucher yet (ADR-034)'
    resp = flask_app.test_client().post(f"/api/invoices/post/{held['id']}", headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    db.session.expire_all()

    at_creation = _create(auth_headers, world, 'scrap_purchase_paid', held=False)
    assert _shape(held['id']) == _shape(at_creation['id']), 'the two writers disagree'
    assert len(_shape(held['id'])) == 1


def test_posting_again_writes_no_second_voucher(auth_headers, world, unposting_allowed):
    held = _create(auth_headers, world, 'scrap_purchase_paid', held=True)
    client = flask_app.test_client()
    assert client.post(f"/api/invoices/post/{held['id']}", headers=auth_headers, json={}).status_code == 200
    from posting_routes import _create_deferred_payment_entries
    from models import Invoice
    _create_deferred_payment_entries(db.session.get(Invoice, held['id']), posted_by='t')
    db.session.flush()
    assert len(_payment_vouchers(held['id'])) == 1
