"""A receipt cancelled whole: one documented entry, the original standing (ADR-087 R1.5 step E).

The owner, 8 Nov 2026: «رفض المستند بعد استلام الذهب لا يعني حذف الاستلام؛ بل
يتطلب مسارًا عكسيًا موثقًا». A receipt for the wrong supplier, or one that
never happened, is cancelled by «تصحيح فاتورة» to nothing: one COR entry
takes the gold out of the safe by what was received, back off the supplier
by his paper, the difference off the count's roles; invoiced, its wages and
their VAT off his cash. Its stage says cancelled, its lines nothing, the
record keeps what was; never unposted, never cancelled twice, not while a
payment stands.

Run:
    python -m pytest tests/test_receiving_cancelled.py -v
"""
import pytest

from models import InvoiceCorrection, InvoiceGoldObligation, InvoiceItem, JournalEntryLine, db
from services.gold_allocation_service import corrected_weight
from services.invoice_corrections import CorrectionRefused, cancel_receipt
from tests.test_receiving_correction import _grams, _received, _twin, showroom  # noqa: F401
from tests.test_receiving_correction_invoiced import _cash, _invoiced, _supplier_cash
from tests.test_stock_count import NOW, roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _cancel(invoice, safe):
    return cancel_receipt(invoice, safe_box_id=safe.id, reason='مورد خاطئ', by='t', now=NOW)


def test_a_receipt_cancelled_takes_its_gold_back_one_entry(auth_headers, world, roles, showroom):
    invoice, item = _received(auth_headers, world, 20.0, 20.05)
    correction = _cancel(invoice, showroom)
    entry = correction.journal_entry_id
    assert _grams(entry, showroom.account_id) == -20.0
    assert _grams(entry, _twin(world)) == 20.05, 'off the supplier by his paper'
    assert _grams(entry, roles['shortage_w'].id) == -0.05, 'the difference off the count'
    assert invoice.receiving_stage == 'cancelled'
    assert db.session.get(InvoiceItem, item.id).weight == 0.0
    assert corrected_weight(InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).one()) == 0.0
    assert InvoiceCorrection.query.filter_by(invoice_id=invoice.id).count() == 1
    assert invoice.is_posted, 'the original stands'


def test_invoiced_its_wages_and_their_vat_come_off_his_cash(auth_headers, world, roles, showroom):
    invoice, _ = _invoiced(auth_headers, world)
    entry = _cancel(invoice, showroom).journal_entry_id
    assert _cash(entry, '1320') == -225.0
    assert _cash(entry, '1400') == -33.75
    assert _supplier_cash(entry, world) == 258.75
    assert (float(invoice.total), float(invoice.gold_subtotal), float(invoice.wage_subtotal)) == (0.0, 0.0, 0.0), \
        'cancelled, it counts in no sum of purchases'


def test_never_twice_and_never_unposted(auth_headers, world, roles, showroom):
    invoice, _ = _received(auth_headers, world, 20.0)
    _cancel(invoice, showroom)
    with pytest.raises(CorrectionRefused) as refused:
        _cancel(invoice, showroom)
    assert refused.value.code == 'receipt_not_cancellable'
    from services.invoice_retraction_guard import received_refusal
    assert received_refusal(invoice)


def test_not_while_a_payment_stands(auth_headers, world, roles, showroom):
    """The reject's guard (invoice_retraction_guard.live_payments_of): a cash
    payment made against the receipt stands -- cancel it first."""
    from models import InvoicePayment, PaymentMethod
    invoice, _ = _invoiced(auth_headers, world)
    method = PaymentMethod.query.first() or PaymentMethod(name='نقد', payment_type='cash', is_active=True)
    db.session.add(method)
    db.session.flush()
    db.session.add(InvoicePayment(invoice_id=invoice.id, payment_method_id=method.id, amount=100.0, net_amount=100.0))
    db.session.flush()
    with pytest.raises(CorrectionRefused) as refused:
        _cancel(invoice, showroom)
    assert refused.value.code == 'receipt_has_payments'
    assert invoice.receiving_stage == 'invoiced'
