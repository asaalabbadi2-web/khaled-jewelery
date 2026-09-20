"""test_phase5_approval_paths_invoice_sync.py
================================================
Phase 5 — approval-path consistency for InvoicePaymentStateService.

Written first as a before-fix regression proof (Step 3): each test creates
an exact scenario and asserts on what is actually observed rather than what
is assumed, per the explicit instruction "if it doesn't create
InvoicePayment at all in this scenario, do not invent behavior — prove what
actually happens first." Two things were proven this way before any code
changed:

  1. Approving a "bare" voucher (reference_type='invoice', built the way the
     general voucher-creation endpoint builds one — no InvoicePayment row
     at all) never moves Invoice.amount_paid/status, on ANY approval path,
     fixed or not — because InvoicePaymentStateService sums InvoicePayment
     rows only, and none exists for this shape. This is a real, separate,
     larger gap (a general voucher payment has no bridge into InvoicePayment
     at all) that this phase does not close — see the Phase 5 report.
     TestPostingRoutesApproveVoucherDoesNotBridgeGeneralVoucherPayments and
     TestRoutesVouchersApproveVoucherSameScenario pin this ceiling on both
     paths so it stays visible rather than silently assumed fixed.

  2. Given an invoice that ALREADY has an InvoicePayment row
     (source_voucher_id pointing at a still-'pending' voucher — the one
     shape where recompute()-at-approval is not a no-op), the three
     approval implementations disagreed: routes/vouchers.py synced the
     invoice, posting_routes.py::approve_voucher and
     ::approve_vouchers_batch did not. That divergence is the actual bug
     this phase fixes, by extracting
     sync_invoice_payment_state_after_voucher_approval (in
     services/invoice_payment_state_service.py) and calling it from all
     three approval code paths. This file now asserts the FIXED,
     consistent behavior for that shape —
     TestApprovalPathsNowAgreeOnInvoicePaymentStateServiceCall and
     TestBatchApprovalTwoIndependentInvoicesEachSyncIndependently.
"""

import json
import uuid
from datetime import datetime

from models import (
    Account,
    Customer,
    Invoice,
    InvoicePayment,
    SafeBox,
    Voucher,
    VoucherAccountLine,
    db,
)
from party_account_service import ensure_customer_accounts


def _uid():
    return uuid.uuid4().hex[:8]


def _customer():
    c = Customer(customer_code=f'CUST-{_uid()}', name='عميل اختبار فيز 5')
    db.session.add(c)
    db.session.flush()
    accounts = ensure_customer_accounts(c)
    db.session.flush()
    return c, accounts.financial.id


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


def _safe_box():
    number = f'99{_uid()[:2]}'
    acc = Account.query.filter_by(account_number=number).first()
    if acc is None:
        acc = Account(account_number=number, name='خزينة اختبار فيز 5', type='Asset')
        db.session.add(acc)
        db.session.flush()
    sb = SafeBox(name=f'خزينة اختبار فيز 5 {_uid()}', safe_type='cash', account_id=acc.id, is_active=True)
    db.session.add(sb)
    db.session.flush()
    return sb


def _bare_invoice_voucher(invoice_id, customer_account_id, amount, status='pending'):
    """A voucher shaped exactly like the GENERAL voucher-creation endpoint
    would produce: reference_type='invoice' pointing at the invoice, real
    VoucherAccountLine rows so create_journal_entry_from_voucher can post
    it — but critically, no InvoicePayment row anywhere. This is the one
    and only thing that distinguishes "recorded through the general voucher
    endpoints" from "recorded through add_invoice_payment/add_invoice",
    which is the exact scenario the original desync bug report described.
    """
    safe_box = _safe_box()
    voucher = Voucher(
        voucher_number=f'V-{_uid()}',
        voucher_type='receipt',
        date=datetime.now(),
        reference_type='invoice',
        reference_id=invoice_id,
        status=status,
        created_by='test',
        amount_cash=amount,
    )
    db.session.add(voucher)
    db.session.flush()
    db.session.add(VoucherAccountLine(
        voucher_id=voucher.id, account_id=safe_box.account_id,
        line_type='debit', amount_type='cash', amount=amount,
    ))
    db.session.add(VoucherAccountLine(
        voucher_id=voucher.id, account_id=customer_account_id,
        line_type='credit', amount_type='cash', amount=amount,
    ))
    db.session.commit()
    return voucher


class TestPostingRoutesApproveVoucherDoesNotBridgeGeneralVoucherPayments:
    """posting_routes.py::approve_voucher — POST /api/vouchers/approve/<id>."""

    def test_full_scenario_via_test_client(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            invoice_id, voucher_id = invoice.id, voucher.id

            before_payment_count = InvoicePayment.query.filter_by(invoice_id=invoice_id).count()
            assert before_payment_count == 0

            resp = client.post(f'/api/vouchers/approve/{voucher_id}', headers=auth_headers)
            assert resp.status_code == 200, resp.data
            payload = json.loads(resp.data)
            assert payload['success'] is True

            voucher_db = Voucher.query.get(voucher_id)
            assert voucher_db.status == 'approved'
            assert voucher_db.journal_entry_id is not None

            # FACT under test: does approving this voucher create/attach an
            # InvoicePayment, or move Invoice.amount_paid/status at all?
            after_payment_count = InvoicePayment.query.filter_by(invoice_id=invoice_id).count()
            invoice_db = Invoice.query.get(invoice_id)

            assert after_payment_count == 0, (
                "posting_routes.py::approve_voucher does not create an "
                "InvoicePayment — confirmed. Approval alone cannot bridge a "
                "general voucher into the invoice's paid total."
            )
            assert invoice_db.amount_paid == 0.0, (
                "Invoice.amount_paid stayed 0 after approving a 10000 receipt "
                "voucher tagged reference_type='invoice' for this exact "
                "invoice — because InvoicePaymentStateService sums "
                "InvoicePayment rows only, and none exists for this voucher. "
                "This IS the original desync bug's ground truth: a voucher "
                "recorded through the general voucher endpoints moves real "
                "money and posts real accounting, but is structurally "
                "invisible to the invoice's cached payment state, "
                "independent of whether the approval endpoint calls "
                "InvoicePaymentStateService.recompute() or not."
            )
            assert invoice_db.status == 'unpaid'


class TestRoutesVouchersApproveVoucherSameScenario:
    """routes/vouchers.py::approve_voucher — POST /vouchers/<id>/approve — the
    endpoint Flutter actually calls, already patched (Phase 2) to call
    InvoicePaymentStateService.recompute(). Same scenario, to prove the
    patched endpoint has the identical ceiling: recompute() cannot see a
    payment that was never turned into an InvoicePayment row."""

    def test_recompute_call_is_a_structural_no_op_for_a_bare_voucher(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            invoice_id, voucher_id = invoice.id, voucher.id

            resp = client.post(f'/api/vouchers/{voucher_id}/approve', headers=auth_headers, json={})
            assert resp.status_code == 200, resp.data

            voucher_db = Voucher.query.get(voucher_id)
            assert voucher_db.status == 'approved'
            assert voucher_db.journal_entry_id is not None

            invoice_db = Invoice.query.get(invoice_id)
            assert InvoicePayment.query.filter_by(invoice_id=invoice_id).count() == 0
            assert invoice_db.amount_paid == 0.0
            assert invoice_db.status == 'unpaid'


class TestApprovalPathsNowAgreeOnInvoicePaymentStateServiceCall:
    """The actual inconsistency Phase 5 fixed: given an invoice that ALREADY
    has an InvoicePayment row (source_voucher_id pointing at a voucher
    created 'pending', not yet approved — the one shape where
    recompute()-at-approval is NOT a no-op), approving that voucher used to
    sync the invoice through routes/vouchers.py but NOT through
    posting_routes.py::approve_voucher. Both now call the same extracted
    helper (sync_invoice_payment_state_after_voucher_approval in
    services/invoice_payment_state_service.py), so both produce the same
    result.

    This shape is not produced by any current caller (every real
    InvoicePayment-creating path self-approves its own voucher inline, per
    routes/invoices.py), but InvoicePaymentStateService's own contract does
    not depend on that — cancel_voucher already proves a payment can
    legitimately still be 'pending' or 'approved' when something about its
    voucher changes. This test pins the fix directly rather than relying on
    that absence-of-caller argument.
    """

    def _invoice_payment(self, invoice_id, pm_id, amount, source_voucher_id):
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

    def test_posting_routes_approve_voucher_now_syncs_the_invoice(self, auth_headers):
        from app import app
        from models import PaymentMethod
        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            pm = PaymentMethod(name=f'وسيلة اختبار {_uid()}', payment_type='cash')
            db.session.add(pm)
            db.session.flush()
            self._invoice_payment(invoice.id, pm.id, 10000.0, source_voucher_id=voucher.id)
            db.session.commit()
            invoice_id, voucher_id = invoice.id, voucher.id

            # Ground truth before approval: recompute() has never run for
            # this invoice, so the cached fields are still at their
            # creation-time defaults regardless of the InvoicePayment row
            # that already exists.
            invoice_before = Invoice.query.get(invoice_id)
            assert invoice_before.amount_paid == 0.0
            assert invoice_before.status == 'unpaid'

            resp = client.post(f'/api/vouchers/approve/{voucher_id}', headers=auth_headers)
            assert resp.status_code == 200, resp.data

            invoice_after = Invoice.query.get(invoice_id)
            assert invoice_after.amount_paid == 10000.0, (
                "posting_routes.py::approve_voucher now calls "
                "sync_invoice_payment_state_after_voucher_approval, the same "
                "helper routes/vouchers.py::approve_voucher uses — the "
                "InvoicePayment row that already existed is now picked up "
                "here too."
            )
            assert invoice_after.status == 'paid'

    def test_routes_vouchers_approve_voucher_syncs_the_same_shape(self, auth_headers):
        from app import app
        from models import PaymentMethod
        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            pm = PaymentMethod(name=f'وسيلة اختبار {_uid()}', payment_type='cash')
            db.session.add(pm)
            db.session.flush()
            self._invoice_payment(invoice.id, pm.id, 10000.0, source_voucher_id=voucher.id)
            db.session.commit()
            invoice_id, voucher_id = invoice.id, voucher.id

            resp = client.post(f'/api/vouchers/{voucher_id}/approve', headers=auth_headers, json={})
            assert resp.status_code == 200, resp.data

            invoice_after = Invoice.query.get(invoice_id)
            assert invoice_after.amount_paid == 10000.0, (
                "routes/vouchers.py::approve_voucher DOES call "
                "InvoicePaymentStateService — the same InvoicePayment row "
                "the posting_routes.py test above left unpicked-up is "
                "reflected here. Same shape, two different outcomes: this "
                "is the concrete proof of the twin-path inconsistency."
            )
            assert invoice_after.status == 'paid'


class TestBatchApprovalTwoIndependentInvoicesEachSyncIndependently:
    """posting_routes.py::approve_vouchers_batch — POST
    /api/vouchers/approve/batch — approving two vouchers for two different
    invoices in one call. Each invoice's own state must update
    independently of the other's."""

    def test_batch_syncs_each_invoice_independently(self, auth_headers):
        from app import app
        from models import PaymentMethod
        with app.app_context():
            client = app.test_client()

            customer_a, account_a = _customer()
            invoice_a = _invoice(customer_a.id, 5000.0)
            voucher_a = _bare_invoice_voucher(invoice_a.id, account_a, 5000.0, status='pending')

            customer_b, account_b = _customer()
            invoice_b = _invoice(customer_b.id, 7000.0)
            voucher_b = _bare_invoice_voucher(invoice_b.id, account_b, 7000.0, status='pending')

            pm = PaymentMethod(name=f'وسيلة اختبار {_uid()}', payment_type='cash')
            db.session.add(pm)
            db.session.flush()
            self_ip = InvoicePayment(
                invoice_id=invoice_a.id, payment_method_id=pm.id,
                amount=5000.0, net_amount=5000.0, source_voucher_id=voucher_a.id,
            )
            db.session.add(self_ip)
            other_ip = InvoicePayment(
                invoice_id=invoice_b.id, payment_method_id=pm.id,
                amount=7000.0, net_amount=7000.0, source_voucher_id=voucher_b.id,
            )
            db.session.add(other_ip)
            db.session.commit()

            invoice_a_id, invoice_b_id = invoice_a.id, invoice_b.id
            voucher_a_id, voucher_b_id = voucher_a.id, voucher_b.id

            resp = client.post(
                '/api/vouchers/approve/batch',
                headers=auth_headers,
                json={'voucher_ids': [voucher_a_id, voucher_b_id]},
            )
            assert resp.status_code == 200, resp.data
            payload = json.loads(resp.data)
            assert payload['success'] is True
            assert payload['approved_count'] == 2, payload

            voucher_a_db = Voucher.query.get(voucher_a_id)
            voucher_b_db = Voucher.query.get(voucher_b_id)
            assert voucher_a_db.status == 'approved'
            assert voucher_b_db.status == 'approved'

            invoice_a_db = Invoice.query.get(invoice_a_id)
            invoice_b_db = Invoice.query.get(invoice_b_id)
            assert invoice_a_db.amount_paid == 5000.0, (
                "approve_vouchers_batch now calls "
                "sync_invoice_payment_state_after_voucher_approval per "
                "voucher inside its loop — invoice A's own InvoicePayment "
                "is picked up independently of invoice B's."
            )
            assert invoice_b_db.amount_paid == 7000.0, "invoice B must sync independently of invoice A."
            assert invoice_a_db.status == 'paid'
            assert invoice_b_db.status == 'paid'


class TestRecomputeFailureIsSwallowedNotRolledBack:
    """Step 6/16 — observe, not assume, what happens when
    InvoicePaymentStateService.recompute() raises during approval.

    Answered as an explicit choice, not a silent default: this phase
    replicates the swallow-and-continue semantics that
    routes/vouchers.py::approve_voucher already shipped (Phase 2) — a
    failed recompute() prints a warning and lets the already-posted
    accounting (JournalEntry, SafeBoxTransaction, voucher.status='approved')
    commit anyway. Making that atomic (rolling back the whole approval if
    the invoice-state sync fails) or otherwise visible beyond a print()
    would be a new accounting/business decision — not made here. These
    tests pin the CURRENT, deliberately-kept behavior at all three call
    sites so a future change to it is a conscious, visible diff.
    """

    def test_posting_routes_approve_voucher_commits_even_if_recompute_raises(self, auth_headers, monkeypatch):
        from app import app
        from services.invoice_payment_state_service import InvoicePaymentStateService

        def _boom(self, invoice):
            raise RuntimeError('simulated recompute failure')

        monkeypatch.setattr(InvoicePaymentStateService, 'recompute', _boom)

        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            voucher_id = voucher.id

            resp = client.post(f'/api/vouchers/approve/{voucher_id}', headers=auth_headers)
            assert resp.status_code == 200, resp.data
            payload = json.loads(resp.data)
            assert payload['success'] is True

            voucher_db = Voucher.query.get(voucher_id)
            assert voucher_db.status == 'approved', (
                "A recompute() failure must not be allowed to silently undo "
                "this — confirming it doesn't, exactly like the pre-existing "
                "routes/vouchers.py path."
            )
            assert voucher_db.journal_entry_id is not None, (
                "Real accounting was posted and committed despite the "
                "invoice-state sync raising — this is the swallow-and-"
                "continue behavior, observed rather than assumed."
            )

    def test_routes_vouchers_approve_voucher_commits_even_if_recompute_raises(self, auth_headers, monkeypatch):
        from app import app
        from services.invoice_payment_state_service import InvoicePaymentStateService

        def _boom(self, invoice):
            raise RuntimeError('simulated recompute failure')

        monkeypatch.setattr(InvoicePaymentStateService, 'recompute', _boom)

        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            voucher_id = voucher.id

            resp = client.post(f'/api/vouchers/{voucher_id}/approve', headers=auth_headers, json={})
            assert resp.status_code == 200, resp.data

            voucher_db = Voucher.query.get(voucher_id)
            assert voucher_db.status == 'approved'
            assert voucher_db.journal_entry_id is not None

    def test_batch_approve_commits_the_voucher_even_if_recompute_raises(self, auth_headers, monkeypatch):
        from app import app
        from services.invoice_payment_state_service import InvoicePaymentStateService

        def _boom(self, invoice):
            raise RuntimeError('simulated recompute failure')

        monkeypatch.setattr(InvoicePaymentStateService, 'recompute', _boom)

        with app.app_context():
            client = app.test_client()
            customer, customer_account_id = _customer()
            invoice = _invoice(customer.id, 10000.0)
            voucher = _bare_invoice_voucher(invoice.id, customer_account_id, 10000.0, status='pending')
            voucher_id = voucher.id

            resp = client.post(
                '/api/vouchers/approve/batch',
                headers=auth_headers,
                json={'voucher_ids': [voucher_id]},
            )
            assert resp.status_code == 200, resp.data
            payload = json.loads(resp.data)
            assert payload['approved_count'] == 1, (
                "approve_vouchers_batch must still count this voucher as "
                "approved — a downstream recompute() failure is swallowed "
                "inside sync_invoice_payment_state_after_voucher_approval "
                "itself, never reaching this loop's own try/except, so it "
                "must not be recorded as a per-voucher batch error either."
            )
            assert payload['errors'] == []

            voucher_db = Voucher.query.get(voucher_id)
            assert voucher_db.status == 'approved'
            assert voucher_db.journal_entry_id is not None
