"""test_phase9a_retire_update_invoice_status.py
==================================================
Phase 9A — retires update_invoice_status as a direct, evidence-free writer
of Invoice.status, and pins the canonical derivation
(InvoicePaymentStateService) as the only way invoice payment-status
changes going forward.

Test A is written to prove the OLD capability is gone (fails red against
the current code, passes once the route is removed). Tests B-E are
regression guards for the canonical derivation itself — they are expected
to already pass today (the canonical flow was never broken; this phase
only removes a redundant, unaudited bypass alongside it) — run once before
the removal and once after, both green. Test F is a static architecture
guard: the only places allowed to write Invoice.status are the canonical
service, documented lifecycle operations (reject/cancel), and the
already-separately-tracked settle_office_reservation writer (Phase 8A-8E,
explicitly out of scope here) — nothing else may accept a raw client
'status' field.
"""
import uuid
from datetime import datetime

from models import Customer, Invoice, InvoicePayment, PaymentMethod, Settings, db


def _allow_partial_payments():
    """add_invoice_payment rejects a partial amount unless
    Settings.allow_partial_invoice_payments is on — a real, pre-existing
    opt-in flag, unrelated to this phase; tests exercising a genuine
    partial payment must enable it explicitly."""
    settings_row = Settings.query.first()
    if settings_row is None:
        settings_row = Settings()
        db.session.add(settings_row)
    settings_row.allow_partial_invoice_payments = True
    db.session.commit()


def _uid():
    return uuid.uuid4().hex[:8]


def _customer():
    c = Customer(customer_code=f'CUST-{_uid()}', name='عميل اختبار 9A')
    db.session.add(c)
    db.session.commit()
    return c


def _payment_method():
    pm = PaymentMethod(name=f'وسيلة اختبار {_uid()}', payment_type='cash')
    db.session.add(pm)
    db.session.commit()
    return pm


def _invoice(customer_id, total):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='بيع', customer_id=customer_id, date=datetime.now(),
        total=total, status='unpaid', amount_paid=0.0, is_posted=True,
    )
    db.session.add(inv)
    db.session.commit()
    return inv


class TestA_DirectStatusMutationNoLongerAnApplicationCapability:
    def test_patch_status_endpoint_is_gone(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            customer = _customer()
            invoice = _invoice(customer.id, 1000.0)

            resp = client.patch(
                f'/api/invoices/{invoice.id}/status',
                headers=auth_headers, json={'status': 'paid'},
            )
            assert resp.status_code == 404, (
                "PATCH /invoices/<id>/status must no longer exist as an "
                f"application capability — got {resp.status_code} instead "
                f"of 404: {resp.data}"
            )


class TestB_CanonicalPaymentFlowStillUpdatesStatus:
    def test_full_payment_via_the_real_endpoint_marks_invoice_paid(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            customer = _customer()
            pm = _payment_method()
            invoice = _invoice(customer.id, 500.0)

            resp = client.post(
                f'/api/invoices/{invoice.id}/payments',
                headers=auth_headers,
                json={'payment_method_id': pm.id, 'amount': 500.0},
            )
            assert resp.status_code == 201, resp.data

            refreshed = Invoice.query.get(invoice.id)
            assert refreshed.status == 'paid'
            assert refreshed.amount_paid == 500.0
            assert InvoicePayment.query.filter_by(invoice_id=invoice.id).count() == 1


class TestC_PartialPayment:
    def test_payment_less_than_total_yields_partially_paid(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            customer = _customer()
            pm = _payment_method()
            invoice = _invoice(customer.id, 1000.0)
            _allow_partial_payments()

            resp = client.post(
                f'/api/invoices/{invoice.id}/payments',
                headers=auth_headers,
                json={'payment_method_id': pm.id, 'amount': 400.0},
            )
            assert resp.status_code == 201, resp.data

            refreshed = Invoice.query.get(invoice.id)
            assert refreshed.status == 'partially_paid'
            assert refreshed.amount_paid == 400.0


class TestD_UnpaidInvoice:
    def test_no_payment_keeps_invoice_unpaid(self, auth_headers):
        from app import app
        from services.invoice_payment_state_service import InvoicePaymentStateService
        with app.app_context():
            customer = _customer()
            invoice = _invoice(customer.id, 750.0)

            # Prove the derivation explicitly (not just the constructor
            # default): zero InvoicePayment rows must derive to 'unpaid'.
            result = InvoicePaymentStateService().recompute(invoice)
            assert result.status == 'unpaid'
            assert result.amount_paid == 0.0


class TestE_PaidInvoice:
    def test_full_payment_recorded_directly_derives_paid(self, auth_headers):
        from app import app
        from services.invoice_payment_state_service import InvoicePaymentStateService
        with app.app_context():
            customer = _customer()
            pm = _payment_method()
            invoice = _invoice(customer.id, 200.0)
            payment = InvoicePayment(
                invoice_id=invoice.id, payment_method_id=pm.id,
                amount=200.0, net_amount=200.0,
            )
            db.session.add(payment)
            db.session.commit()

            result = InvoicePaymentStateService().recompute(invoice)
            assert result.status == 'paid'
            assert result.amount_paid == 200.0


class TestRejectionUnaffected:
    """Phase 9A must not change reject_invoice's own documented lifecycle
    behavior — it is a separately-classified, intentional writer (category
    3: cancellation/rejection), not the bypass being removed."""

    def test_reject_invoice_still_works_exactly_as_before(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            customer = _customer()
            invoice = _invoice(customer.id, 300.0)
            invoice.is_posted = False  # reject_invoice's own precondition
            db.session.commit()

            resp = client.post(
                f'/api/invoices/{invoice.id}/reject',
                headers=auth_headers, json={},
            )
            assert resp.status_code == 200, resp.data

            refreshed = Invoice.query.get(invoice.id)
            assert refreshed.status == 'rejected'


class TestF_NoManualBypassElsewhere:
    """Static architecture guard: after this phase, the ONLY places in the
    non-test codebase allowed to write Invoice.status are the canonical
    service, reject_invoice's documented lifecycle write, the one-off
    devtools repair script, and settle_office_reservation's already
    separately-tracked writer (Phase 8A-8E; explicitly out of scope here).
    Nothing else may read a raw client 'status' field for an Invoice.
    """

    def test_no_other_endpoint_accepts_a_raw_status_field(self):
        # Scoped precisely to Invoice.status writers (not a generic
        # 'status' scan — bonus/payroll/attendance records also have their
        # own unrelated 'status' fields and would be false positives here).
        import re
        import pathlib

        backend_dir = pathlib.Path(__file__).parent
        offending = []
        allowed_files = {
            'services/invoice_payment_state_service.py',
            'routes/invoices.py',  # reject_invoice's own literal 'rejected' write
            'routes/office_reservations.py',  # Phase 8A-8E, tracked separately
            'devtools/post_unposted_imported_invoices.py',
        }
        patterns = [
            re.compile(r"invoice\.status\s*="),
            re.compile(r"new_invoice\.status\s*="),
            re.compile(r"inv\.status\s*="),
            re.compile(r"purchase_invoice\.status\s*="),
            re.compile(r"status\s*=\s*invoice_status\b"),
        ]
        for path in backend_dir.rglob('*.py'):
            rel = str(path.relative_to(backend_dir))
            if rel.startswith('venv/') or '/test_' in rel or rel.startswith('test_'):
                continue
            if rel in allowed_files:
                continue
            text = path.read_text(encoding='utf-8', errors='ignore')
            if any(p.search(text) for p in patterns):
                offending.append(rel)

        assert offending == [], (
            f"found an Invoice.status writer outside the allowed set: {offending}"
        )

    def test_update_invoice_status_function_is_gone(self):
        import routes.invoices as invoices_module
        assert not hasattr(invoices_module, 'update_invoice_status'), (
            "update_invoice_status must be removed from routes/invoices.py entirely"
        )
