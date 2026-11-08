"""The supplier's gold owed follows his paper and its corrections (ADR-087 R1.5 step D; ADR-028).

A purchase's gold obligation is the ORIGINAL debt, one immutable row a karat
(ADR-028): the ledger is the one truth, the balance derived. Receiving made
it from the weight received; the supplier is owed his paper (§4) -- so it is
made from his paper. A correction (step B) never edits it: the invoice's gold
owed is the original plus its corrections' differences, read where the
obligation's weight was read -- the invoice's gold status, its attributed
remainder, the supplier's reconciliation. A received line's karat is not
corrected here: the obligation is a karat's.

Run:
    python -m pytest tests/test_receiving_obligations.py -v
"""
import pytest

from models import InvoiceGoldObligation, db
from services.gold_allocation_service import corrected_weight, reconcile_supplier
from services.invoice_corrections import CorrectionRefused
from tests.test_receiving_correction import _correct, _received, showroom  # noqa: F401
from tests.test_stock_count import roles  # noqa: F401
from tests.test_supplier_purchase_effect import app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401


def _obligation(invoice):
    return InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).one()


def test_the_obligation_is_his_paper(auth_headers, world, roles):
    invoice, _ = _received(auth_headers, world, 20.0, 20.05)
    assert _obligation(invoice).weight == 20.05


def test_corrected_the_original_stands_and_the_owed_follows(auth_headers, world, roles, showroom):
    invoice, item = _received(auth_headers, world, 20.0)
    gross_before = reconcile_supplier(world['supplier'])['gross_obligation']
    _correct(invoice, item, showroom, weight=19.5)
    obligation = _obligation(invoice)
    assert obligation.weight == 20.0, 'the original, immutable'
    assert corrected_weight(obligation) == 19.5
    assert reconcile_supplier(world['supplier'])['gross_obligation'] == pytest.approx(gross_before - 0.5)
    from services.invoice_payment_state_service import InvoicePaymentStateService
    required, _ = InvoicePaymentStateService._gold_dimension(invoice)
    assert required == pytest.approx(19.5), 'its gold required is the corrected (main karat 21)'


def test_a_received_lines_karat_is_not_corrected_here(auth_headers, world, roles, showroom):
    invoice, item = _received(auth_headers, world, 20.0)
    with pytest.raises(CorrectionRefused) as refused:
        _correct(invoice, item, showroom, weight=20.0, karat=18)
    assert refused.value.code == 'correction_receipt_karat_not_built'
