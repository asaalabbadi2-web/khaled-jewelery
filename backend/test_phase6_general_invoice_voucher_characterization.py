"""test_phase6_general_invoice_voucher_characterization.py
=============================================================
Phase 6 — CHARACTERIZATION tests only. These pin CURRENT behavior for a
newly-identified root cause; they do not encode a business rule that has
been decided on, and they must not be read as "this is correct." No
production code changes in this phase.

Root cause characterized here: routes/office_reservations.py's
settle_office_reservation relinks a voucher created earlier (during the
reservation, tagged reference_type='office_reservation', voucher_type=
'payment' — a real deposit already paid) onto the purchase_invoice it
results in:

    linked = Voucher.query.filter_by(reference_type='office_reservation', reference_id=reservation.id).all()
    for v in linked:
        v.reference_type = 'invoice'
        v.reference_id = purchase_invoice.id
        ...

This never creates an InvoicePayment. InvoicePaymentStateService only sums
InvoicePayment rows, so it cannot see this relinked voucher no matter when
or how often recompute() runs. This is not a sync-timing bug (Phase 5's
class of problem) — recompute() called at any point produces the same
blind result, because the payment was never represented in the one place
this service reads from.

Empirical note: in prodcopy_phase5 (a real, isolated copy of production
data), exactly 17 of the 47 stored-vs-recomputed invoice mismatches match
this exact shape (a reference_type='invoice' voucher with real amount_cash,
approved, journal_entry_id set, zero InvoicePayment rows for that invoice)
— the single largest root cause found in Phase 6's mismatch breakdown.
"""
import uuid
from datetime import datetime

from models import Account, Customer, Invoice, InvoicePayment, SafeBox, Voucher, VoucherAccountLine, db
from party_account_service import ensure_customer_accounts
from services.invoice_payment_state_service import InvoicePaymentStateService


def _uid():
    return uuid.uuid4().hex[:8]


class TestReservationRelinkedVoucherIsInvisibleToStateService:
    def test_relinked_voucher_never_produces_an_invoice_payment_or_paid_amount(self):
        from app import app
        with app.app_context():
            customer = Customer(customer_code=f'CUST-{_uid()}', name='عميل اختبار فيز 6')
            db.session.add(customer)
            db.session.flush()
            accounts = ensure_customer_accounts(customer)
            db.session.flush()
            customer_account_id = accounts.financial.id

            acc_number = f'98{_uid()[:2]}'
            safe_account = Account(account_number=acc_number, name='خزينة اختبار فيز 6', type='Asset')
            db.session.add(safe_account)
            db.session.flush()
            safe_box = SafeBox(name=f'خزينة فيز 6 {_uid()}', safe_type='cash', account_id=safe_account.id, is_active=True)
            db.session.add(safe_box)
            db.session.flush()

            # Step 1 — the reservation deposit: a REAL, approved, posted
            # voucher, created and tagged exactly the way
            # routes/office_reservations.py::create_office_reservation does
            # (reference_type='office_reservation', voucher_type='payment').
            deposit_voucher = Voucher(
                voucher_number=f'V-{_uid()}',
                voucher_type='payment',
                date=datetime.now(),
                reference_type='office_reservation',
                reference_id=9999001,
                status='approved',
                created_by='flutter_app',
                amount_cash=5000.0,
            )
            db.session.add(deposit_voucher)
            db.session.flush()
            db.session.add(VoucherAccountLine(
                voucher_id=deposit_voucher.id, account_id=safe_account.id,
                line_type='credit', amount_type='cash', amount=5000.0,
            ))
            db.session.add(VoucherAccountLine(
                voucher_id=deposit_voucher.id, account_id=customer_account_id,
                line_type='debit', amount_type='cash', amount=5000.0,
            ))
            db.session.commit()

            # Step 2 — the purchase invoice this reservation settles into.
            invoice = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1,
                invoice_type='شراء',
                customer_id=customer.id,
                date=datetime.now(),
                total=5000.0,
                status='unpaid',
                amount_paid=0.0,
                is_posted=True,
            )
            db.session.add(invoice)
            db.session.flush()
            invoice_id = invoice.id
            deposit_voucher_id = deposit_voucher.id

            # Step 3 — the EXACT relink routes/office_reservations.py
            # performs at settlement (office_reservations.py:508-513): only
            # reference_type/reference_id/reference_number change. No
            # InvoicePayment is created; source_voucher_id is not touched.
            v = Voucher.query.get(deposit_voucher_id)
            v.reference_type = 'invoice'
            v.reference_id = invoice_id
            v.reference_number = str(invoice_id)
            db.session.add(v)
            db.session.commit()

            # FACT under test: the invoice now has a real, approved,
            # posted, invoice-tagged voucher worth its exact total — but
            # InvoicePaymentStateService still sees nothing.
            assert InvoicePayment.query.filter_by(invoice_id=invoice_id).count() == 0
            assert Voucher.query.filter_by(reference_type='invoice', reference_id=invoice_id).count() == 1

            result = InvoicePaymentStateService().recompute(invoice)
            assert result.amount_paid == 0.0, (
                "recompute() cannot see the relinked deposit voucher under "
                "any circumstances, at any point in time — it only reads "
                "InvoicePayment rows, and this workflow never creates one. "
                "This is a structural gap, not a call-timing gap: calling "
                "recompute() again, or sooner, or from a different call "
                "site, changes nothing here."
            )
            assert result.status == 'unpaid'
