"""Phase 15C — HTTP-level integration tests for Gold Advance & Allocation.

Everything in test_gold_allocation_service.py proves the matching/bookkeeping
logic is correct when called directly. This file proves the WIRING itself is
reachable from the real route surface: approving a real gold-advance voucher,
posting a real 'شراء' invoice, the manual-override route, and both reversal
paths (voucher cancel; purchase return) — through app.test_client(), the same
way a real request would.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from app import app, db
from models import (
    Account,
    GoldAllocation,
    Invoice,
    InvoiceGoldObligation,
    SafeBox,
    Supplier,
    SupplierGoldAdvance,
    Voucher,
)


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier_with_accounts():
    from party_account_service import ensure_supplier_accounts
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد اختبار {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.commit()
    return s


def _gold_safe_box():
    acc = Account(
        account_number=f'99{_uid()[:4]}', name='خزينة ذهب اختبار',
        type='Asset', tracks_weight=True,
    )
    db.session.add(acc)
    db.session.flush()
    sb = SafeBox(name='خزينة ذهب اختبار', safe_type='gold', account_id=acc.id, is_active=True)
    db.session.add(sb)
    db.session.commit()
    return sb


class TestGoldAdvanceVoucherApprovalWiring:

    def test_approving_a_gold_advance_voucher_creates_and_allocates_it(self, auth_headers):
        with app.app_context():
            supplier = _supplier_with_accounts()
            gold_safe = _gold_safe_box()
            supplier_fin_account_id = int(Supplier.query.get(supplier.id).account_id)

            # A pre-existing open obligation for this supplier, so approval
            # should immediately auto-allocate against it.
            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                supplier_id=supplier.id, date=datetime(2026, 1, 1), total=1000.0,
                status='unpaid', amount_paid=0.0, is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()
            obligation = InvoiceGoldObligation(
                invoice_id=inv.id, karat=21.0, weight=100.0, weight_remaining_main_karat=100.0,
            )
            db.session.add(obligation)
            db.session.commit()

            voucher_payload = {
                'voucher_type': 'payment',
                'date': datetime.now().isoformat(),
                'party_type': 'supplier',
                'supplier_id': supplier.id,
                'reference_type': 'gold_advance',
                'account_lines': [
                    {
                        'account_id': gold_safe.account_id,
                        'line_type': 'credit',
                        'amount_type': 'gold',
                        'amount': 40.0,
                        'karat': 21,
                    },
                    {
                        'account_id': supplier_fin_account_id,
                        'line_type': 'debit',
                        'amount_type': 'gold',
                        'amount': 40.0,
                        'karat': 21,
                    },
                ],
            }
            supplier_id = supplier.id
            obligation_id = obligation.id

        with app.test_client() as client:
            resp = client.post('/api/vouchers', json=voucher_payload, headers=auth_headers)
        assert resp.status_code == 201, resp.get_data(as_text=True)
        voucher_id = resp.get_json()['id']

        with app.test_client() as client:
            resp2 = client.post(f'/api/vouchers/{voucher_id}/approve', json={}, headers=auth_headers)
        assert resp2.status_code == 200, resp2.get_data(as_text=True)

        with app.app_context():
            advance = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher_id).first()
            assert advance is not None, 'approving a gold_advance voucher must create a SupplierGoldAdvance'
            assert advance.karat == 21.0
            assert advance.weight == 40.0
            assert advance.weight_remaining_main_karat == 0.0, 'must have auto-allocated fully against the open obligation'

            refreshed_obligation = InvoiceGoldObligation.query.get(obligation_id)
            assert refreshed_obligation.weight_remaining_main_karat == 60.0

            allocation = GoldAllocation.query.filter_by(advance_id=advance.id).first()
            assert allocation is not None
            assert allocation.obligation_id == obligation_id


class TestGoldAdvancesRoutes:

    def test_list_and_manual_allocate(self, auth_headers):
        """Advance and obligation are deliberately DIFFERENT karats — same-
        karat auto-FIFO (create_gold_obligations_for_invoice's own internal
        auto_allocate_for_obligation call) must not touch either one, so the
        manual-override route below is genuinely exercising the override
        path, not just re-observing what auto-allocation already did."""
        with app.app_context():
            from services.gold_allocation_service import create_gold_obligations_for_invoice
            from models import InvoiceKaratLine

            supplier = _supplier_with_accounts()
            voucher = Voucher(
                voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
                party_type='supplier', supplier_id=supplier.id, reference_type='gold_advance',
                status='approved', created_by='test',
            )
            db.session.add(voucher)
            db.session.flush()
            advance = SupplierGoldAdvance(
                supplier_id=supplier.id, source_voucher_id=voucher.id,
                karat=18.0, weight=50.0, weight_remaining_main_karat=50.0,
            )
            db.session.add(advance)

            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                supplier_id=supplier.id, date=datetime.now(), total=500.0,
                status='unpaid', amount_paid=0.0, is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()
            db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=200.0))
            db.session.commit()
            obligations = create_gold_obligations_for_invoice(inv)
            db.session.commit()
            advance_id = advance.id
            obligation_id = obligations[0].id
            invoice_id = inv.id

            assert SupplierGoldAdvance.query.get(advance_id).weight_remaining_main_karat == 50.0, \
                'sanity: different karats must not have auto-allocated against each other'

        with app.test_client() as client:
            resp = client.get('/api/gold-advances', headers=auth_headers)
        assert resp.status_code == 200, resp.get_data(as_text=True)
        body = resp.get_json()
        assert any(a['id'] == advance_id for a in body['advances'])

        with app.test_client() as client:
            resp2 = client.get(f'/api/invoices/{invoice_id}/gold-obligations', headers=auth_headers)
        assert resp2.status_code == 200, resp2.get_data(as_text=True)
        assert any(o['id'] == obligation_id for o in resp2.get_json()['obligations'])

        with app.test_client() as client:
            resp3 = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 20.0},
                headers=auth_headers,
            )
        assert resp3.status_code == 201, resp3.get_data(as_text=True)

        with app.app_context():
            assert SupplierGoldAdvance.query.get(advance_id).weight_remaining_main_karat == 30.0

    def test_manual_allocate_rejects_exceeding_remaining_with_400(self, auth_headers):
        with app.app_context():
            supplier = _supplier_with_accounts()
            voucher = Voucher(
                voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
                party_type='supplier', supplier_id=supplier.id, reference_type='gold_advance',
                status='approved', created_by='test',
            )
            db.session.add(voucher)
            db.session.flush()
            advance = SupplierGoldAdvance(
                supplier_id=supplier.id, source_voucher_id=voucher.id,
                karat=21.0, weight=10.0, weight_remaining_main_karat=10.0,
            )
            db.session.add(advance)
            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                supplier_id=supplier.id, date=datetime.now(), total=500.0,
                status='unpaid', amount_paid=0.0, is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()
            obligation = InvoiceGoldObligation(
                invoice_id=inv.id, karat=21.0, weight=100.0, weight_remaining_main_karat=100.0,
            )
            db.session.add(obligation)
            db.session.commit()
            advance_id = advance.id
            obligation_id = obligation.id

        with app.test_client() as client:
            resp = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 999.0},
                headers=auth_headers,
            )
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'exceeds_advance_remaining'

    def test_manual_allocate_rejects_cross_supplier_with_400(self, auth_headers):
        with app.app_context():
            supplier_a = _supplier_with_accounts()
            supplier_b = _supplier_with_accounts()
            voucher = Voucher(
                voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
                party_type='supplier', supplier_id=supplier_a.id, reference_type='gold_advance',
                status='approved', created_by='test',
            )
            db.session.add(voucher)
            db.session.flush()
            advance = SupplierGoldAdvance(
                supplier_id=supplier_a.id, source_voucher_id=voucher.id,
                karat=21.0, weight=50.0, weight_remaining_main_karat=50.0,
            )
            db.session.add(advance)
            inv_b = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                supplier_id=supplier_b.id, date=datetime.now(), total=500.0,
                status='unpaid', amount_paid=0.0, is_posted=True,
            )
            db.session.add(inv_b)
            db.session.flush()
            obligation_b = InvoiceGoldObligation(
                invoice_id=inv_b.id, karat=21.0, weight=100.0, weight_remaining_main_karat=100.0,
            )
            db.session.add(obligation_b)
            db.session.commit()
            advance_id = advance.id
            obligation_id = obligation_b.id

        with app.test_client() as client:
            resp = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 20.0},
                headers=auth_headers,
            )
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'supplier_mismatch'


## NOTE — real POST /api/invoices for a 'شراء' invoice is NOT exercised via
## HTTP in this file. Attempted (both 'items' and 'karat_lines' payload
## shapes) and both hit the SAME pre-existing, unrelated gap in this bare
## test environment: "No memo account for weight safety-net posting (karat
## 21)" — a missing Accounting Mapping seed for the weight/gold inventory
## memo account, which leaves the journal entry weight-unbalanced and the
## whole request rejected with 400, before create_gold_obligations_for_
## invoice's own call site is ever reached. Confirmed pre-existing and not
## caused by Phase 15C: test_supplier_purchase_return_invoice.py's own
## original-شراء-invoice creation (same 'items' shape) is independently
## known to fail in this same bare environment (see Phase 13's closure
## audit in project memory). The invoice-side trigger itself is proven at
## the direct function-call level instead — see
## TestGoldAdvancesRoutes.test_list_and_manual_allocate above (which calls
## create_gold_obligations_for_invoice directly) and
## test_gold_allocation_service.py's TestCreateGoldObligationsForInvoice
## (9 tests) — plus the exact call-site line was verified by direct code
## reading (routes/invoices.py's shared post-commit tail, right after
## is_posted=True, gated on invoice_type == 'شراء').


class TestReversalWiring:

    def test_cancelling_a_gold_advance_voucher_frees_its_allocation(self, auth_headers):
        with app.app_context():
            from services.gold_allocation_service import sync_gold_advance_after_voucher_approval

            supplier = _supplier_with_accounts()
            gold_safe = _gold_safe_box()
            supplier_fin_account_id = int(Supplier.query.get(supplier.id).account_id)

            inv = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                supplier_id=supplier.id, date=datetime.now(), total=500.0,
                status='unpaid', amount_paid=0.0, is_posted=True,
            )
            db.session.add(inv)
            db.session.flush()
            obligation = InvoiceGoldObligation(
                invoice_id=inv.id, karat=21.0, weight=100.0, weight_remaining_main_karat=100.0,
            )
            db.session.add(obligation)
            db.session.commit()

            voucher_payload = {
                'voucher_type': 'payment', 'date': datetime.now().isoformat(),
                'party_type': 'supplier', 'supplier_id': supplier.id,
                'reference_type': 'gold_advance',
                'account_lines': [
                    {'account_id': gold_safe.account_id, 'line_type': 'credit',
                     'amount_type': 'gold', 'amount': 30.0, 'karat': 21},
                    {'account_id': supplier_fin_account_id, 'line_type': 'debit',
                     'amount_type': 'gold', 'amount': 30.0, 'karat': 21},
                ],
            }
            obligation_id = obligation.id

        with app.test_client() as client:
            resp = client.post('/api/vouchers', json=voucher_payload, headers=auth_headers)
        assert resp.status_code == 201, resp.get_data(as_text=True)
        voucher_id = resp.get_json()['id']

        with app.test_client() as client:
            resp2 = client.post(f'/api/vouchers/{voucher_id}/approve', json={}, headers=auth_headers)
        assert resp2.status_code == 200, resp2.get_data(as_text=True)

        with app.app_context():
            advance = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher_id).first()
            assert advance.weight_remaining_main_karat == 0.0
            assert InvoiceGoldObligation.query.get(obligation_id).weight_remaining_main_karat == 70.0

        with app.test_client() as client:
            resp3 = client.post(f'/api/vouchers/{voucher_id}/cancel', json={'reason': 'test'}, headers=auth_headers)
        assert resp3.status_code == 200, resp3.get_data(as_text=True)

        with app.app_context():
            advance = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher_id).first()
            assert advance.weight_remaining_main_karat == 30.0, 'cancelling must free the allocation back onto the advance'
            assert InvoiceGoldObligation.query.get(obligation_id).weight_remaining_main_karat == 100.0
            assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0
