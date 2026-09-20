"""test_phase9c_reservation_invoice_payment.py
=================================================
Phase 9C — office reservation deposits become real InvoicePayment rows.

Two decisions confirmed before writing any of this (see the Phase 9C
report): (1) payment_method_id becomes required at reservation-creation
time whenever paid_amount > 0, with safe_box_id derived from it (matching
add_invoice_payment's existing convention, not a new pattern); (2)
settle_office_reservation stops directly writing Invoice.amount_paid/
status and instead creates a real InvoicePayment (source_voucher_id ->
the deposit voucher), routed through InvoicePaymentStateService — and the
Phase 8E reversal orchestrator is extended to remove that InvoicePayment
on reject, exactly mirroring how it already removes the
WeightClosingExecution row.

Fixture strategy matches test_phase8e_reservation_settlement_reversal.py:
direct ORM construction for Office/Supplier/the source sale invoice +
weight-closing order (proven reliable there), but this file drives the
REAL create_office_reservation and settle_office_reservation HTTP
endpoints for creation/settlement specifically, since those are exactly
what changed.
"""
import json
import uuid
from datetime import datetime

from models import (
    Account,
    Invoice,
    InvoicePayment,
    JournalEntry,
    Office,
    OfficeReservation,
    PaymentMethod,
    Supplier,
    Voucher,
    WeightClosingOrder,
    db,
)
from routes import DEFAULT_WEIGHT_CLOSING_SETTINGS, _upsert_weight_closing_order


def _uid():
    return uuid.uuid4().hex[:8]


def _payment_method(safe_box_id):
    pm = PaymentMethod(
        name=f'وسيلة اختبار 9C {_uid()}', payment_type='cash',
        default_safe_box_id=safe_box_id,
    )
    db.session.add(pm)
    db.session.commit()
    return pm


def _safe_box_with_account():
    acc = Account(
        account_number=f'TST9C{_uid()}', name=f'حساب خزينة 9C {_uid()}',
        type='Asset', transaction_type='cash',
    )
    db.session.add(acc)
    db.session.flush()
    from models import SafeBox
    sb = SafeBox(name=f'خزينة اختبار 9C {_uid()}', safe_type='cash', account_id=acc.id, is_active=True)
    db.session.add(sb)
    db.session.commit()
    return sb


def _office_and_supplier():
    office_account = Account(
        account_number=f'TST9C{_uid()}', name=f'حساب مكتب 9C {_uid()}',
        type='Liability', transaction_type='cash',
    )
    db.session.add(office_account)
    db.session.flush()
    office = Office(office_code=f'OFF9C-{_uid()}', name=f'مكتب اختبار 9C {_uid()}', active=True)
    office.account_category_id = office_account.id
    db.session.add(office)
    db.session.flush()
    supplier = Supplier(supplier_code=f'SUP9C-{_uid()}', name=f'مورد اختبار 9C {_uid()}')
    db.session.add(supplier)
    db.session.flush()
    office.supplier_id = supplier.id
    db.session.add(office)
    db.session.commit()
    return office


def _source_sale_invoice_with_open_order(weight_main_karat):
    sale_invoice = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='بيع', date=datetime.now(), total=0.0, status='unpaid',
        amount_paid=0.0, is_posted=True,
    )
    db.session.add(sale_invoice)
    db.session.flush()
    order = WeightClosingOrder(
        invoice_id=sale_invoice.id, order_number=f'WCO9C-{_uid()}', status='open',
        total_weight_main_karat=weight_main_karat, executed_weight_main_karat=0.0,
        remaining_weight_main_karat=weight_main_karat, close_price_per_gram=230.0,
    )
    db.session.add(order)
    db.session.commit()
    return order


def _ensure_purchases_account():
    if not Account.query.filter_by(account_number='512').first():
        db.session.add(Account(
            account_number='512', name='مشتريات ذهب كسر',
            type='Expense', transaction_type='cash',
        ))
        db.session.commit()


class TestReservationRequiresPaymentMethod:
    def test_reservation_with_deposit_but_no_payment_method_id_is_rejected(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            office = _office_and_supplier()

            resp = client.post(
                '/api/office-reservations', headers=auth_headers,
                json={
                    'office_id': office.id,
                    'weight': 2.5, 'price_per_gram': 230.0,
                    'execution_price_per_gram': 230.0, 'paid_amount': 575.0,
                },
            )
            assert resp.status_code == 400, resp.data
            body = json.loads(resp.data)
            assert body.get('error') == 'invalid_payment_method_id'

    def test_zero_deposit_reservation_does_not_require_payment_method_id(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            office = _office_and_supplier()

            resp = client.post(
                '/api/office-reservations', headers=auth_headers,
                json={
                    'office_id': office.id,
                    'weight': 2.5, 'price_per_gram': 230.0,
                    'execution_price_per_gram': 230.0, 'paid_amount': 0.0,
                },
            )
            assert resp.status_code == 201, resp.data


class TestSafeBoxDerivedFromPaymentMethod:
    def test_safe_box_is_derived_not_client_supplied(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            office = _office_and_supplier()
            safe_box = _safe_box_with_account()
            pm = _payment_method(safe_box.id)

            # A DIFFERENT, unrelated safe_box_id sent by the client must be
            # ignored entirely — only payment_method_id drives routing now.
            unrelated_safe_box = _safe_box_with_account()

            resp = client.post(
                '/api/office-reservations', headers=auth_headers,
                json={
                    'office_id': office.id,
                    'weight': 2.5, 'price_per_gram': 230.0,
                    'execution_price_per_gram': 230.0, 'paid_amount': 575.0,
                    'payment_method_id': pm.id,
                    'safe_box_id': unrelated_safe_box.id,
                },
            )
            assert resp.status_code == 201, resp.data
            data = json.loads(resp.data)
            reservation = OfficeReservation.query.get(data['id'])
            assert reservation.payment_method_id == pm.id

            voucher = Voucher.query.get(data['payment_voucher_id'])
            line_account_ids = {l.account_id for l in voucher.account_lines.all()}
            assert safe_box.account_id in line_account_ids
            assert unrelated_safe_box.account_id not in line_account_ids


class TestSettlementCreatesRealInvoicePayment:
    def test_settle_creates_invoice_payment_linked_to_deposit_voucher(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            _ensure_purchases_account()
            office = _office_and_supplier()
            safe_box = _safe_box_with_account()
            pm = _payment_method(safe_box.id)
            order = _source_sale_invoice_with_open_order(2.5)

            create_resp = client.post(
                '/api/office-reservations', headers=auth_headers,
                json={
                    'office_id': office.id,
                    'weight': 2.5, 'price_per_gram': 230.0,
                    'execution_price_per_gram': 230.0, 'paid_amount': 575.0,
                    'payment_method_id': pm.id,
                },
            )
            assert create_resp.status_code == 201, create_resp.data
            created = json.loads(create_resp.data)
            reservation_id = created['id']
            deposit_voucher_id = created['payment_voucher_id']

            settle_resp = client.post(
                f'/api/office-reservations/{reservation_id}/settle',
                headers=auth_headers, json={'execution_price_per_gram': 230.0},
            )
            assert settle_resp.status_code == 200, settle_resp.data
            invoice_id = json.loads(settle_resp.data)['purchase_invoice_id']

            payments = InvoicePayment.query.filter_by(invoice_id=invoice_id).all()
            assert len(payments) == 1
            payment = payments[0]
            assert payment.source_voucher_id == deposit_voucher_id
            assert payment.payment_method_id == pm.id
            assert payment.amount == 575.0

            invoice = Invoice.query.get(invoice_id)
            assert invoice.status == 'paid'
            assert invoice.amount_paid == 575.0

            # Prove it's derived, not copied: recompute() again must be a
            # true no-op (changed=False) if the stored value already
            # matches the canonical formula.
            from services.invoice_payment_state_service import InvoicePaymentStateService
            result = InvoicePaymentStateService().recompute(invoice)
            assert result.changed is False

            # Test-only cleanup: this test's own order should already be
            # 'closed' (fully consumed), but these tests commit to the
            # real dev DB with no rollback and weight-closing consumption
            # is a global FIFO pool unscoped to any one reservation (see
            # the same note in test_phase8e_reservation_settlement_reversal.py)
            # — force it closed explicitly so a leftover can never leak
            # into a later, unrelated test regardless of which physical
            # order the FIFO match actually consumed from.
            db.session.expire_all()
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).update({'status': 'closed'}, synchronize_session=False)
            db.session.commit()


class TestLegacyReservationWithoutPaymentMethodIsRefused:
    def test_settle_refuses_a_legacy_deposit_with_no_payment_method_id(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            _ensure_purchases_account()
            office = _office_and_supplier()
            safe_box = _safe_box_with_account()
            order = _source_sale_invoice_with_open_order(2.5)

            # Simulate a pre-Phase-9C reservation: a real deposit voucher
            # exists (created the old way), but payment_method_id is NULL.
            reservation = OfficeReservation(
                office_id=office.id, reservation_code=f'RES9C-{_uid()}',
                weight_grams=2.5, weight_main_karat=2.5, price_per_gram=230.0,
                execution_price_per_gram=230.0, total_amount=575.0,
                paid_amount=575.0, payment_status='paid', status='approved',
                payment_method_id=None,
            )
            db.session.add(reservation)
            db.session.flush()
            voucher = Voucher(
                voucher_number=f'V9C-{_uid()}', voucher_type='payment', date=datetime.now(),
                party_type='supplier', supplier_id=office.supplier_id,
                reference_type='office_reservation', reference_id=reservation.id,
                status='approved', amount_cash=575.0, amount_gold=0.0,
            )
            db.session.add(voucher)
            db.session.commit()

            settle_resp = client.post(
                f'/api/office-reservations/{reservation.id}/settle',
                headers=auth_headers, json={'execution_price_per_gram': 230.0},
            )
            assert settle_resp.status_code == 400, settle_resp.data
            body = json.loads(settle_resp.data)
            assert body.get('error') == 'legacy_deposit_missing_payment_method'

            # Confirmed refusal, not a silent fallback: no invoice created.
            db.session.expire_all()
            assert OfficeReservation.query.get(reservation.id).purchase_invoice_id is None

            # Test-only cleanup: the refused settle never touches this
            # order at all, so it would otherwise leak into the shared
            # FIFO pool forever — see the note in
            # TestSettlementCreatesRealInvoicePayment above.
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).update({'status': 'closed'}, synchronize_session=False)
            db.session.commit()


class TestRejectReversesInvoicePaymentToo:
    def test_reject_removes_the_invoice_payment_and_resettle_creates_a_fresh_one(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            _ensure_purchases_account()
            office = _office_and_supplier()
            safe_box = _safe_box_with_account()
            pm = _payment_method(safe_box.id)
            order = _source_sale_invoice_with_open_order(2.5)

            created = json.loads(client.post(
                '/api/office-reservations', headers=auth_headers,
                json={
                    'office_id': office.id,
                    'weight': 2.5, 'price_per_gram': 230.0,
                    'execution_price_per_gram': 230.0, 'paid_amount': 575.0,
                    'payment_method_id': pm.id,
                },
            ).data)
            reservation_id = created['id']
            deposit_voucher_id = created['payment_voucher_id']

            settle_a = json.loads(client.post(
                f'/api/office-reservations/{reservation_id}/settle',
                headers=auth_headers, json={'execution_price_per_gram': 230.0},
            ).data)
            invoice_a_id = settle_a['purchase_invoice_id']
            assert InvoicePayment.query.filter_by(invoice_id=invoice_a_id).count() == 1

            reject_resp = client.post(
                f'/api/invoices/{invoice_a_id}/reject', headers=auth_headers, json={},
            )
            assert reject_resp.status_code == 200, reject_resp.data

            db.session.expire_all()
            assert InvoicePayment.query.filter_by(invoice_id=invoice_a_id).count() == 0, (
                "the InvoicePayment created for the rejected settlement must be removed, "
                "exactly like the WeightClosingExecution row is"
            )

            settle_b = json.loads(client.post(
                f'/api/office-reservations/{reservation_id}/settle',
                headers=auth_headers, json={'execution_price_per_gram': 230.0},
            ).data)
            invoice_b_id = settle_b['purchase_invoice_id']
            assert invoice_b_id != invoice_a_id

            payments_b = InvoicePayment.query.filter_by(invoice_id=invoice_b_id).all()
            assert len(payments_b) == 1
            assert payments_b[0].source_voucher_id == deposit_voucher_id
            assert payments_b[0].amount == 575.0

            invoice_b = Invoice.query.get(invoice_b_id)
            assert invoice_b.status == 'paid'
            assert invoice_b.amount_paid == 575.0

            # Test-only cleanup — see the note in
            # TestSettlementCreatesRealInvoicePayment above.
            db.session.expire_all()
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).update({'status': 'closed'}, synchronize_session=False)
            db.session.commit()
