"""test_phase13_cash_obligation_for_purchase_invoices.py
==========================================================
Phase 13 of the invoice-payment-status audit: for invoice_type='شراء'
(registered-supplier purchase), Invoice.total conflates the raw gold value
(a barter/inventory concept, never a cash debt on the supplier — see
routes/invoices.py's own "ليست التزامًا على المورد" comment on the
memo-account gold posting) with the real cash owed. InvoicePaymentStateService
used to compare amount_paid against `total` for every invoice_type
identically; it now compares against Invoice.cash_obligation instead, for
'شراء' only. Every other invoice_type is unaffected — cash_obligation equals
total for them by definition.

Formula (Phase 12A-12C, empirically verified against real production data —
see invoice #52 and others in the yasargold_realprod_20260920 restore):
    cash_obligation = wage_subtotal (0 if the supplier is gold-wage-paid)
                     + wage_tax_total
                     + gold_tax_total
"""

import uuid
from datetime import datetime

from app import app
from models import Invoice, InvoicePayment, PaymentMethod, Supplier, db
from services.invoice_payment_state_service import InvoicePaymentStateService


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier(default_wage_type='cash'):
    s = Supplier(
        supplier_code=f'SUP-{_uid()}',
        name=f'مورد اختبار {_uid()}',
        default_wage_type=default_wage_type,
    )
    db.session.add(s)
    db.session.flush()
    return s


def _payment_method():
    pm = PaymentMethod(name=f'وسيلة اختبار {_uid()}', payment_type='cash')
    db.session.add(pm)
    db.session.flush()
    return pm


def _purchase_invoice(supplier_id, *, total, gold_subtotal=0.0, wage_subtotal=0.0,
                       wage_tax_total=0.0, gold_tax_total=0.0):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='شراء',
        supplier_id=supplier_id,
        date=datetime.now(),
        total=total,
        gold_subtotal=gold_subtotal,
        wage_subtotal=wage_subtotal,
        wage_tax_total=wage_tax_total,
        gold_tax_total=gold_tax_total,
        status='unpaid',
        amount_paid=0.0,
        is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _invoice_payment(invoice_id, pm_id, amount):
    ip = InvoicePayment(
        invoice_id=invoice_id,
        payment_method_id=pm_id,
        amount=amount,
        net_amount=amount,
    )
    db.session.add(ip)
    db.session.flush()
    return ip


class TestCashObligationProperty:
    """Invoice.cash_obligation itself — the single source of truth both
    InvoicePaymentStateService and the frontend's remaining-balance display
    now read from."""

    def test_non_purchase_invoice_cash_obligation_equals_total(self):
        with app.app_context():
            # Mirrors an existing 'بيع'/'شراء من عميل' invoice: no supplier,
            # a large total dominated by a "gold_subtotal"-shaped value that
            # would be wrongly excluded if the شراء branch fired here.
            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1,
                invoice_type='بيع',
                date=datetime.now(),
                total=798337.32,
                gold_subtotal=747922.49,
                wage_subtotal=50414.83,
                status='unpaid',
                amount_paid=0.0,
                is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()

            assert inv.cash_obligation == 798337.32

    def test_scrap_purchase_from_walkin_customer_cash_obligation_equals_total(self):
        """invoice_type='شراء من عميل' (walk-in customer scrap purchase) is a
        genuinely different, all-immediate-cash scenario (Phase 12B) — it
        must never be caught by the 'شراء' branch. It has no supplier_id at
        all, so this also proves the property does not crash or misbehave
        without one."""
        with app.app_context():
            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1,
                invoice_type='شراء من عميل',
                date=datetime.now(),
                total=5000.0,
                gold_subtotal=4600.0,
                wage_subtotal=0.0,
                status='unpaid',
                amount_paid=0.0,
                is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()

            assert inv.cash_obligation == 5000.0

    def test_purchase_invoice_cash_obligation_excludes_gold_value(self):
        """Reproduces invoice #52 from the real production restore exactly:
        total=798337.32 (94% gold_subtotal=747922.49), wage_subtotal=50414.83,
        both taxes 0 (VAT-exempt in that real invoice). The real cash owed —
        verified directly against that invoice's own GL posting (JE#71,
        net cash_credit to the supplier's financial account) — is exactly
        the wage_subtotal, 50414.83. Not ~778,337 (total - 20,000 paid)."""
        with app.app_context():
            supplier = _supplier(default_wage_type='cash')
            inv = _purchase_invoice(
                supplier.id, total=798337.32, gold_subtotal=747922.49,
                wage_subtotal=50414.83, wage_tax_total=0.0, gold_tax_total=0.0,
            )
            assert inv.cash_obligation == 50414.83

    def test_wage_tax_and_gold_tax_both_included(self):
        """Mirrors real invoice #58: wage_subtotal=2491.0, wage_tax_total=373.65
        — verified against its own GL posting (net cash_credit to the
        supplier's financial account = 2864.65 exactly)."""
        with app.app_context():
            supplier = _supplier(default_wage_type='cash')
            inv = _purchase_invoice(
                supplier.id, total=50000.0, gold_subtotal=46000.0,
                wage_subtotal=2491.0, wage_tax_total=373.65, gold_tax_total=0.0,
            )
            assert inv.cash_obligation == 2864.65

    def test_gold_payable_wage_is_excluded_entirely(self):
        """When the supplier is paid its manufacturing wage in gold weight
        instead of cash (Supplier.default_wage_type='gold'), wage_subtotal is
        not a cash debt at all — only its VAT (always cash) and any gold VAT
        remain. Not observed in real production today (0 suppliers currently
        use default_wage_type='gold'), but this is the exact rule Phase
        12A/12C established and it must not silently regress."""
        with app.app_context():
            supplier = _supplier(default_wage_type='gold')
            inv = _purchase_invoice(
                supplier.id, total=50000.0, gold_subtotal=46000.0,
                wage_subtotal=2491.0, wage_tax_total=373.65, gold_tax_total=0.0,
            )
            assert inv.cash_obligation == 373.65


class TestInvoicePaymentStateServiceUsesCashObligationForPurchases:
    """The actual bug: 'سداد المتبقي' and Invoice.status both used to compare
    amount_paid against `total`, which is wrong for 'شراء' — this is what
    would show a purchase invoice as still owing hundreds of thousands of
    riyals in gold value the supplier was never owed in cash."""

    def test_paying_exactly_the_wage_marks_a_gold_heavy_purchase_paid(self):
        with app.app_context():
            supplier = _supplier(default_wage_type='cash')
            inv = _purchase_invoice(
                supplier.id, total=798337.32, gold_subtotal=747922.49,
                wage_subtotal=50414.83, wage_tax_total=0.0, gold_tax_total=0.0,
            )
            pm = _payment_method()
            _invoice_payment(inv.id, pm.id, 50414.83)
            db.session.commit()

            state = InvoicePaymentStateService().recompute(inv)
            db.session.commit()

            assert state.obligation_ceiling == 50414.83
            assert inv.amount_paid == 50414.83, (
                'amount_paid must still be the real sum of InvoicePayment '
                'rows, unchanged by this fix'
            )
            assert inv.status == 'paid', (
                "paying the full real cash obligation (50,414.83) must mark "
                "the invoice paid, even though it is far below total "
                "(798,337.32) — the old code compared against total and "
                "would have left this 'partially_paid' forever"
            )

    def test_partial_wage_payment_is_partially_paid_not_paid(self):
        with app.app_context():
            supplier = _supplier(default_wage_type='cash')
            inv = _purchase_invoice(
                supplier.id, total=798337.32, gold_subtotal=747922.49,
                wage_subtotal=50414.83, wage_tax_total=0.0, gold_tax_total=0.0,
            )
            pm = _payment_method()
            _invoice_payment(inv.id, pm.id, 20000.0)
            db.session.commit()

            InvoicePaymentStateService().recompute(inv)
            db.session.commit()

            assert inv.amount_paid == 20000.0
            assert inv.status == 'partially_paid'

    def test_overpayment_beyond_cash_obligation_reads_paid_not_negative(self):
        """A payment recorded above the real cash obligation (e.g. a small
        cash rounding settlement on top of the wage) must still resolve to
        'paid', never a negative or otherwise nonsensical remaining amount.
        Mirrors Phase 12C's one known real overpayment case (invoice 553,
        1.03 SAR rounding artifact) — same shape, applied to 'شراء'."""
        with app.app_context():
            supplier = _supplier(default_wage_type='cash')
            inv = _purchase_invoice(
                supplier.id, total=798337.32, gold_subtotal=747922.49,
                wage_subtotal=50414.83, wage_tax_total=0.0, gold_tax_total=0.0,
            )
            pm = _payment_method()
            _invoice_payment(inv.id, pm.id, 50415.86)  # 1.03 over the real obligation
            db.session.commit()

            state = InvoicePaymentStateService().recompute(inv)
            db.session.commit()

            assert state.obligation_ceiling == 50414.83
            assert inv.amount_paid == 50415.86
            assert inv.status == 'paid'
            # The frontend's own remaining = (cash_obligation - amount_paid)
            # would be negative here (-1.03) without its existing .clamp(0.0,
            # double.infinity) — unchanged by this phase, but worth pinning
            # the raw arithmetic explicitly so a future refactor notices.
            assert (state.obligation_ceiling - inv.amount_paid) < 0

    def test_non_purchase_invoice_status_logic_is_unchanged(self):
        """Regression guard: a 'بيع' invoice must keep comparing against the
        full total exactly as before this phase."""
        with app.app_context():
            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1,
                invoice_type='بيع',
                date=datetime.now(),
                total=1000.0,
                status='unpaid',
                amount_paid=0.0,
                is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()
            pm = _payment_method()
            _invoice_payment(inv.id, pm.id, 400.0)
            db.session.commit()

            state = InvoicePaymentStateService().recompute(inv)
            db.session.commit()

            assert state.obligation_ceiling == 1000.0
            assert inv.status == 'partially_paid'

            _invoice_payment(inv.id, pm.id, 600.0)
            db.session.commit()
            InvoicePaymentStateService().recompute(inv)
            db.session.commit()
            assert inv.status == 'paid'
