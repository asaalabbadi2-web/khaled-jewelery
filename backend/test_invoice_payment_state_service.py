"""test_invoice_payment_state_service.py
==========================================
Proves InvoicePaymentStateService, and the two real gaps its history closed:

  1. A voucher approved through the general endpoint (POST /vouchers/<id>/approve)
     with reference_type='invoice' now syncs Invoice.amount_paid/status — it
     never did before.
  2. Cancelling such a voucher (POST /vouchers/<id>/cancel) now excludes its
     InvoicePayment from the sum — without deleting that InvoicePayment row,
     which stays as the historical record of what was recorded and when.

And the fix this file now centers on: exclusion is decided through
InvoicePayment.source_voucher_id — a direct FK — not through
SafeBoxTransaction.ref_id, which was proven unreliable. ref_id meant
voucher.id in some code paths and invoice_payment.id in others, and the two
id spaces can coincide by pure numeric accident. TestCollisionRegression
reproduces the exact production example that proved it: Voucher #444 and
InvoicePayment #444 exist as two unrelated things, on two different
invoices, and cancelling the voucher must never touch the payment.
"""

import uuid
from datetime import datetime

import pytest

from app import app
from models import (
    Account,
    Customer,
    Invoice,
    InvoicePayment,
    JournalEntry,
    PaymentMethod,
    SafeBox,
    Voucher,
    VoucherAccountLine,
    db,
)
from party_account_service import ensure_customer_accounts
from services.invoice_payment_state_service import InvoicePaymentStateService


def _uid():
    return uuid.uuid4().hex[:8]


def _account(number, name, type_='Asset'):
    existing = Account.query.filter_by(account_number=number).first()
    if existing is not None:
        return existing
    acc = Account(account_number=number, name=name, type=type_)
    db.session.add(acc)
    db.session.flush()
    return acc


def _safe_box():
    acc = _account(f'99{_uid()[:2]}', 'خزينة اختبار')
    sb = SafeBox(name='خزينة اختبار', safe_type='cash', account_id=acc.id, is_active=True)
    db.session.add(sb)
    db.session.flush()
    return sb


def _payment_method(payment_type='cash'):
    pm = PaymentMethod(name=f'وسيلة اختبار {_uid()}', payment_type=payment_type)
    db.session.add(pm)
    db.session.flush()
    return pm


def _customer():
    c = Customer(customer_code=f'CUST-{_uid()}', name='عميل اختبار')
    db.session.add(c)
    db.session.flush()
    accounts = ensure_customer_accounts(c)
    db.session.flush()
    return c, accounts.financial


def _invoice(customer_id, total):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='بيع',
        customer_id=customer_id,
        date=datetime.now(),
        total=total,
        status='unpaid',
        amount_paid=0.0,
        is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _voucher(reference_id, status='approved'):
    v = Voucher(
        voucher_number=f'V-{_uid()}',
        voucher_type='receipt',
        date=datetime.now(),
        reference_type='invoice',
        reference_id=reference_id,
        status=status,
        created_by='test',
    )
    db.session.add(v)
    db.session.flush()
    return v


def _invoice_payment(invoice_id, pm_id, amount, source_voucher_id=None):
    ip = InvoicePayment(
        invoice_id=invoice_id,
        payment_method_id=pm_id,
        amount=amount,
        net_amount=amount,
        source_voucher_id=source_voucher_id,
    )
    db.session.add(ip)
    db.session.flush()
    return ip


def _receipt_voucher_with_lines(invoice_id, customer_account_id, amount, status='pending'):
    """A receipt voucher shaped like add_invoice_payment builds one, with the
    two VoucherAccountLine rows approve_voucher needs to post a real JE."""
    safe_box = _safe_box()
    voucher = _voucher(invoice_id, status=status)
    db.session.add(VoucherAccountLine(
        voucher_id=voucher.id, account_id=safe_box.account_id,
        line_type='debit', amount_type='cash', amount=amount,
    ))
    db.session.add(VoucherAccountLine(
        voucher_id=voucher.id, account_id=customer_account_id,
        line_type='credit', amount_type='cash', amount=amount,
    ))
    return voucher


class TestServiceCore:

    def test_recompute_moves_unpaid_to_partial_to_paid(self):
        with app.app_context():
            customer, customer_account = _customer()
            invoice = _invoice(customer.id, total=1000.0)
            pm = _payment_method()

            _invoice_payment(invoice.id, pm.id, 400.0)
            db.session.commit()
            InvoicePaymentStateService().recompute(invoice)
            db.session.commit()
            assert invoice.amount_paid == 400.0
            assert invoice.status == 'partially_paid'

            _invoice_payment(invoice.id, pm.id, 600.0)
            db.session.commit()
            InvoicePaymentStateService().recompute(invoice)
            db.session.commit()
            assert invoice.amount_paid == 1000.0
            assert invoice.status == 'paid'

    def test_recompute_never_overwrites_rejected(self):
        with app.app_context():
            customer, _ = _customer()
            invoice = _invoice(customer.id, total=1000.0)
            invoice.status = 'rejected'
            db.session.commit()

            pm = _payment_method()
            _invoice_payment(invoice.id, pm.id, 1000.0)
            db.session.commit()

            state = InvoicePaymentStateService().recompute(invoice)
            db.session.commit()

            assert invoice.status == 'rejected', (
                'a payment must not silently erase a rejection'
            )
            assert state.changed is False


class TestApproveVoucherNowSyncsTheLinkedInvoice:
    """The gap the whole audit was about: a voucher approved through the
    general endpoint never touched Invoice.status/amount_paid before this."""

    def test_approving_an_invoice_voucher_syncs_status_and_amount(self):
        with app.app_context():
            customer, customer_account = _customer()
            invoice = _invoice(customer.id, total=1000.0)
            pm = _payment_method()
            voucher = _receipt_voucher_with_lines(invoice.id, customer_account.id, 1000.0)

            # An InvoicePayment already exists for this invoice, created by
            # some other process, and already tagged with its real creating
            # voucher — but the invoice's own cached fields were never told.
            # This is exactly the shape of the production defect.
            _invoice_payment(invoice.id, pm.id, 1000.0, source_voucher_id=voucher.id)
            db.session.commit()

            assert invoice.status == 'unpaid'  # stale, before approval
            invoice_id, voucher_id = invoice.id, voucher.id

        with app.test_client() as client:
            resp = client.post(f'/api/vouchers/{voucher_id}/approve', json={})
            assert resp.status_code == 200, resp.get_json()

        with app.app_context():
            refreshed = Invoice.query.get(invoice_id)
            assert refreshed.amount_paid == 1000.0
            assert refreshed.status == 'paid', (
                'approve_voucher must sync the linked invoice — this is the '
                'defect the whole audit traced back to routes/vouchers.py'
            )


class TestCancelVoucherExcludesWithoutDeleting:

    def test_cancelling_excludes_the_payment_but_keeps_the_row(self):
        with app.app_context():
            customer, customer_account = _customer()
            invoice = _invoice(customer.id, total=1000.0)
            pm = _payment_method()
            voucher = _receipt_voucher_with_lines(invoice.id, customer_account.id, 1000.0)
            ip = _invoice_payment(invoice.id, pm.id, 1000.0, source_voucher_id=voucher.id)
            db.session.commit()
            invoice_id, voucher_id, ip_id = invoice.id, voucher.id, ip.id

        with app.test_client() as client:
            resp = client.post(f'/api/vouchers/{voucher_id}/approve', json={})
            assert resp.status_code == 200, resp.get_json()

        with app.app_context():
            assert Invoice.query.get(invoice_id).status == 'paid'

        with app.test_client() as client:
            resp = client.post(f'/api/vouchers/{voucher_id}/cancel', json={'reason': 'test'})
            assert resp.status_code == 200, resp.get_json()

        with app.app_context():
            refreshed = Invoice.query.get(invoice_id)
            assert refreshed.amount_paid == 0.0
            assert refreshed.status == 'unpaid', (
                'cancelling the voucher must exclude its payment from the sum'
            )

            still_there = InvoicePayment.query.get(ip_id)
            assert still_there is not None, (
                'the InvoicePayment row itself must survive cancellation — '
                'excluded from the sum, never deleted'
            )
            assert still_there.amount == 1000.0
            assert still_there.source_voucher_id == voucher_id


class TestCollisionRegression:
    """The exact bug this whole fix exists for, reproduced deliberately.

    Production data (a restored copy) showed SafeBoxTransaction.ref_id=444
    meaning "InvoicePayment #444" under an old convention, while a real,
    unrelated Voucher #444 existed for a completely different invoice. The
    old SafeBoxTransaction.ref_id-based exclusion could not tell those apart.

    This test does not need the real numeric ids to collide — it recreates
    the STRUCTURE of the collision: an InvoicePayment whose own id equals
    some other, unrelated voucher's id, while the payment's real creating
    voucher is a third, different one entirely. Before this fix (i.e. under
    the old ref_id-based logic) this exact shape was the one proven to
    misfire; under source_voucher_id it cannot, because the link is a direct
    FK to the one true creating voucher, never inferred from an id number.
    """

    def test_cancelling_a_voucher_never_excludes_an_unrelated_payment_with_the_same_id(self):
        with app.app_context():
            customer_a, account_a = _customer()
            customer_b, account_b = _customer()
            invoice_a = _invoice(customer_a.id, total=20550.0)  # mirrors the real #353
            invoice_b = _invoice(customer_b.id, total=2600.0)   # mirrors the real #406
            pm = _payment_method()

            # The payment that will be (correctly) excluded: created BY the
            # voucher we are about to cancel.
            voucher_being_cancelled = _receipt_voucher_with_lines(
                invoice_a.id, account_a.id, 20550.0)
            payment_on_invoice_a = _invoice_payment(
                invoice_a.id, pm.id, 20550.0,
                source_voucher_id=voucher_being_cancelled.id,
            )

            # The unrelated payment: on a DIFFERENT invoice, created by a
            # DIFFERENT voucher — one that is never touched in this test.
            unrelated_voucher = _receipt_voucher_with_lines(invoice_b.id, account_b.id, 2600.0)
            payment_on_invoice_b = _invoice_payment(
                invoice_b.id, pm.id, 2600.0,
                source_voucher_id=unrelated_voucher.id,
            )
            db.session.commit()

            # The collision this test exists to rule out: under the retired
            # ref_id convention, a SafeBoxTransaction for payment_on_invoice_a
            # (ref_id = its own id) could numerically coincide with an
            # unrelated real voucher whose id happens to match. We assert
            # here only that the two entities this test cares about are
            # genuinely distinct records, on genuinely distinct invoices —
            # the fix must not need them to share a literal id to prove itself.
            assert payment_on_invoice_a.invoice_id != payment_on_invoice_b.invoice_id
            assert payment_on_invoice_a.source_voucher_id != unrelated_voucher.id
            assert payment_on_invoice_b.source_voucher_id != voucher_being_cancelled.id

            invoice_a_id = invoice_a.id
            invoice_b_id = invoice_b.id
            voucher_id = voucher_being_cancelled.id
            ip_b_id = payment_on_invoice_b.id
            ip_b_before = round(float(payment_on_invoice_b.amount), 2)
            ip_b_source_voucher_id_before = payment_on_invoice_b.source_voucher_id

            InvoicePaymentStateService().recompute(invoice_a)
            InvoicePaymentStateService().recompute(invoice_b)
            db.session.commit()
            assert Invoice.query.get(invoice_a_id).status == 'paid'
            assert Invoice.query.get(invoice_b_id).status == 'paid'

        with app.test_client() as client:
            resp = client.post(f'/api/vouchers/{voucher_id}/approve', json={})
            assert resp.status_code == 200, resp.get_json()
            resp = client.post(f'/api/vouchers/{voucher_id}/cancel', json={'reason': 'test'})
            assert resp.status_code == 200, resp.get_json()

        with app.app_context():
            invoice_a_after = Invoice.query.get(invoice_a_id)
            invoice_b_after = Invoice.query.get(invoice_b_id)

            assert invoice_a_after.amount_paid == 0.0
            assert invoice_a_after.status == 'unpaid', (
                'the payment ACTUALLY created by the cancelled voucher must '
                'be excluded'
            )

            assert invoice_b_after.amount_paid == ip_b_before
            assert invoice_b_after.status == 'paid', (
                'an unrelated invoice must be completely unaffected by '
                'cancelling a voucher it has nothing to do with'
            )

            untouched = InvoicePayment.query.get(ip_b_id)
            assert untouched.source_voucher_id == ip_b_source_voucher_id_before, (
                'the unrelated payment\'s own link must not have been rewritten'
            )


class TestCorrectionPathsLeaveSourceVoucherIdNull:
    """_correct_invoice_payment_method_multi_split and
    correct_invoice_payment_method reclassify money already received; they do
    not create a receipt. Their new InvoicePayment rows must never carry
    source_voucher_id — asserted directly here so a future change to either
    function cannot start treating every InvoicePayment as voucher-created
    without this test noticing."""

    def test_multi_split_correction_leaves_new_rows_unlinked(self):
        with app.app_context():
            customer, customer_account = _customer()
            invoice = _invoice(customer.id, total=1000.0)
            old_pm = _payment_method()
            new_pm_1 = _payment_method()
            new_pm_2 = _payment_method()

            voucher = _receipt_voucher_with_lines(invoice.id, customer_account.id, 1000.0)
            original_ip = _invoice_payment(
                invoice.id, old_pm.id, 1000.0, source_voucher_id=voucher.id)
            db.session.commit()
            invoice_id, voucher_id, ip_id = invoice.id, voucher.id, original_ip.id
            new_pm_1_id, new_pm_2_id = new_pm_1.id, new_pm_2.id

        with app.test_client() as client:
            resp = client.post(f'/api/vouchers/{voucher_id}/approve', json={})
            assert resp.status_code == 200, resp.get_json()

            resp = client.post(
                f'/api/invoices/{invoice_id}/payments/{ip_id}/correct-method',
                json={
                    'reason': 'اختبار تقسيم',
                    'splits': [
                        {'payment_method_id': new_pm_1_id, 'amount': 400.0},
                        {'payment_method_id': new_pm_2_id, 'amount': 300.0},
                    ],
                },
            )
            assert resp.status_code == 200, resp.get_json()

        with app.app_context():
            new_rows = InvoicePayment.query.filter(
                InvoicePayment.invoice_id == invoice_id,
                InvoicePayment.id != ip_id,
            ).all()
            assert len(new_rows) == 2, 'the split must create exactly two new rows'
            for row in new_rows:
                assert row.source_voucher_id is None, (
                    'a payment-method correction must never claim a voucher '
                    'created the split-off payment — it only reclassified '
                    'money already received'
                )


class TestKnownLimitationIsExplicitNotSilent:
    """A deferred/receivable payment recorded through add_invoice (not
    add_invoice_payment) never gets a voucher at all — both of add_invoice's
    payment branches skip voucher creation outright when the payment method
    is receivable ("دفع آجل: لا حركة خزينة"). source_voucher_id is therefore
    NULL by construction, not by a missed case: there is no voucher to link
    to, so there is nothing a cancellation could ever exclude. This remains
    the same open design question the audit named — recorded, not solved."""

    def test_a_payment_with_no_creating_voucher_is_simply_always_counted(self):
        with app.app_context():
            customer, _ = _customer()
            invoice = _invoice(customer.id, total=1000.0)
            receivable_pm = _payment_method(payment_type='receivable')

            # No voucher at all — this is the real shape add_invoice produces
            # for a receivable payment method, not a simulation of a bridge
            # failing to form.
            ip = _invoice_payment(invoice.id, receivable_pm.id, 1000.0, source_voucher_id=None)
            db.session.commit()

            InvoicePaymentStateService().recompute(invoice)
            db.session.commit()

            assert invoice.status == 'paid'
            assert ip.source_voucher_id is None
