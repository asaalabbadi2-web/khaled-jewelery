"""Phase 16C — HTTP-level integration tests for Gold Advance & Allocation.

test_gold_allocation_service.py proves the logic is correct when called
directly. This file proves the WIRING is reachable from the real route
surface: approving a real gold-advance voucher, the allocate route, the
reconciliation route, and the cancellation reversal path — through
app.test_client(), the same way a real request would.

The behavioural change Phase 16C makes is asserted here at HTTP level too:
approving a gold-advance voucher while an open same-karat obligation exists
must create the Advance and allocate NOTHING. Under Phase 15 that same request
auto-allocated, which is how the model came to report 31,407g of "remaining"
against a real GL position of 3,446g.
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


def _purchase_invoice(supplier_id, *, date=None, total=1000.0):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier_id, date=date or datetime.now(), total=total,
        status='unpaid', amount_paid=0.0, is_posted=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _gold_advance_voucher_payload(supplier_id, gold_account_id, supplier_account_id, weight, karat=21):
    return {
        'voucher_type': 'payment',
        'date': datetime.now().isoformat(),
        'party_type': 'supplier',
        'supplier_id': supplier_id,
        'reference_type': 'gold_advance',
        'account_lines': [
            {'account_id': gold_account_id, 'line_type': 'credit',
             'amount_type': 'gold', 'amount': weight, 'karat': karat},
            {'account_id': supplier_account_id, 'line_type': 'debit',
             'amount_type': 'gold', 'amount': weight, 'karat': karat},
        ],
    }


class TestGoldAdvanceVoucherApprovalWiring:

    def test_approving_a_gold_advance_voucher_creates_it_unallocated(self, auth_headers):
        """The Advance is recorded; nothing is attributed to the open
        obligation, because nobody said it should be."""
        with app.app_context():
            supplier = _supplier_with_accounts()
            gold_safe = _gold_safe_box()
            supplier_fin_account_id = int(Supplier.query.get(supplier.id).account_id)

            inv = _purchase_invoice(supplier.id, date=datetime(2026, 1, 1))
            obligation = InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=100.0)
            db.session.add(obligation)
            db.session.commit()

            voucher_payload = _gold_advance_voucher_payload(
                supplier.id, gold_safe.account_id, supplier_fin_account_id, 40.0,
            )
            obligation_id = obligation.id

        with app.test_client() as client:
            resp = client.post('/api/vouchers', json=voucher_payload, headers=auth_headers)
        assert resp.status_code == 201, resp.get_data(as_text=True)
        voucher_id = resp.get_json()['id']

        with app.test_client() as client:
            resp2 = client.post(f'/api/vouchers/{voucher_id}/approve', json={}, headers=auth_headers)
        assert resp2.status_code == 200, resp2.get_data(as_text=True)

        with app.app_context():
            from services.gold_allocation_service import (
                advance_remaining,
                obligation_attributed_remaining,
            )

            advance = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher_id).first()
            assert advance is not None, 'approving a gold_advance voucher must create a SupplierGoldAdvance'
            assert advance.karat == 21.0
            assert advance.weight == 40.0

            assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0, \
                'Phase 16C: approval must attribute nothing'
            assert advance_remaining(advance) == 40.0, 'the whole advance stays unallocated'

            refreshed = InvoiceGoldObligation.query.get(obligation_id)
            assert obligation_attributed_remaining(refreshed) == 100.0, \
                'the obligation must not be credited by an advance nobody allocated'


class TestGoldAdvancesRoutes:

    def test_list_obligations_and_allocate(self, auth_headers):
        with app.app_context():
            from models import InvoiceKaratLine
            from services.gold_allocation_service import create_gold_obligations_for_invoice

            supplier = _supplier_with_accounts()
            voucher = Voucher(
                voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
                party_type='supplier', supplier_id=supplier.id, reference_type='gold_advance',
                status='approved', created_by='test',
            )
            db.session.add(voucher)
            db.session.flush()
            advance = SupplierGoldAdvance(
                supplier_id=supplier.id, source_voucher_id=voucher.id, karat=21.0, weight=50.0,
            )
            db.session.add(advance)

            inv = _purchase_invoice(supplier.id, total=500.0)
            db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=200.0))
            db.session.commit()
            obligations = create_gold_obligations_for_invoice(inv)
            db.session.commit()

            advance_id = advance.id
            obligation_id = obligations[0].id
            invoice_id = inv.id

            assert GoldAllocation.query.filter_by(advance_id=advance.id).count() == 0, \
                'sanity: creating obligations must not have attributed the open advance'

        with app.test_client() as client:
            resp = client.get('/api/gold-advances', headers=auth_headers)
        assert resp.status_code == 200, resp.get_data(as_text=True)
        listed = {a['id']: a for a in resp.get_json()['advances']}
        assert advance_id in listed
        assert listed[advance_id]['remaining_main_karat'] == 50.0, \
            'the route reports a DERIVED remaining, not a stored column'

        with app.test_client() as client:
            resp2 = client.get(f'/api/invoices/{invoice_id}/gold-obligations', headers=auth_headers)
        assert resp2.status_code == 200, resp2.get_data(as_text=True)
        obligation_payloads = {o['id']: o for o in resp2.get_json()['obligations']}
        assert obligation_id in obligation_payloads
        payload = obligation_payloads[obligation_id]
        assert payload['attributed_remaining_main_karat'] == 200.0
        assert payload['attributed_settlement_main_karat'] == 0.0
        assert 'weight_remaining_main_karat' not in payload, \
            'the misleading generic name must not reappear on the wire'

        with app.test_client() as client:
            resp3 = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 20.0},
                headers=auth_headers,
            )
        assert resp3.status_code == 201, resp3.get_data(as_text=True)

        with app.app_context():
            from services.gold_allocation_service import advance_remaining
            assert advance_remaining(SupplierGoldAdvance.query.get(advance_id)) == 30.0

    def test_allocate_rejects_exceeding_remaining_with_400(self, auth_headers):
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
                supplier_id=supplier.id, source_voucher_id=voucher.id, karat=21.0, weight=10.0,
            )
            db.session.add(advance)

            inv = _purchase_invoice(supplier.id)
            obligation = InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=100.0)
            db.session.add(obligation)
            db.session.commit()
            advance_id, obligation_id = advance.id, obligation.id

        with app.test_client() as client:
            resp = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 50.0},
                headers=auth_headers,
            )
        assert resp.status_code == 400, resp.get_data(as_text=True)
        assert resp.get_json()['error'] == 'exceeds_advance_remaining'

    def test_allocate_rejects_cross_supplier_with_400(self, auth_headers):
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
            advance_a = SupplierGoldAdvance(
                supplier_id=supplier_a.id, source_voucher_id=voucher.id, karat=21.0, weight=50.0,
            )
            db.session.add(advance_a)

            inv_b = _purchase_invoice(supplier_b.id)
            obligation_b = InvoiceGoldObligation(invoice_id=inv_b.id, karat=21.0, weight=100.0)
            db.session.add(obligation_b)
            db.session.commit()
            advance_id, obligation_id = advance_a.id, obligation_b.id

        with app.test_client() as client:
            resp = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 10.0},
                headers=auth_headers,
            )
        assert resp.status_code == 400, resp.get_data(as_text=True)
        assert resp.get_json()['error'] == 'supplier_mismatch'


class TestReconciliationRoute:

    def test_reports_the_named_unattributed_residual(self, auth_headers):
        """The route surface must expose the residual, not just the invoice
        rows — otherwise a caller summing obligations re-derives the wrong
        number with nothing to contradict it."""
        with app.app_context():
            from datetime import timedelta

            from models import JournalEntry, JournalEntryLine
            from party_account_service import ensure_supplier_accounts

            supplier = _supplier_with_accounts()
            accounts = ensure_supplier_accounts(supplier)

            inv = _purchase_invoice(supplier.id)
            db.session.add(InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=100.0))

            je = JournalEntry(
                entry_number=f'JE-{_uid()}', date=datetime.now() - timedelta(days=1),
                description='قيد اختباري', entry_type='عادي',
                is_posted=True, is_draft=False, created_by='test',
            )
            db.session.add(je)
            db.session.flush()
            db.session.add_all([
                JournalEntryLine(
                    journal_entry_id=je.id, account_id=accounts.financial.id,
                    supplier_id=supplier.id, credit_21k=100.0, description='التزام',
                ),
                JournalEntryLine(
                    journal_entry_id=je.id, account_id=accounts.financial.id,
                    supplier_id=supplier.id, debit_21k=40.0, description='دفعة عامة',
                ),
            ])
            db.session.commit()
            supplier_id = supplier.id

        with app.test_client() as client:
            resp = client.get(
                f'/api/suppliers/{supplier_id}/gold-reconciliation', headers=auth_headers,
            )
        assert resp.status_code == 200, resp.get_data(as_text=True)
        rec = resp.get_json()['reconciliation']

        assert rec['unit'] == 'main_karat_equivalent'
        assert rec['gross_obligation'] == 100.0
        assert rec['attributed_settlement'] == 0.0
        assert rec['unattributed_settlement'] == 40.0
        assert rec['gl_position'] == 60.0


class TestReversalWiring:

    def test_cancelling_a_gold_advance_voucher_frees_its_allocation(self, auth_headers):
        with app.app_context():
            supplier = _supplier_with_accounts()
            gold_safe = _gold_safe_box()
            supplier_fin_account_id = int(Supplier.query.get(supplier.id).account_id)

            inv = _purchase_invoice(supplier.id, total=500.0)
            obligation = InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=100.0)
            db.session.add(obligation)
            db.session.commit()

            voucher_payload = _gold_advance_voucher_payload(
                supplier.id, gold_safe.account_id, supplier_fin_account_id, 30.0,
            )
            obligation_id = obligation.id

        with app.test_client() as client:
            resp = client.post('/api/vouchers', json=voucher_payload, headers=auth_headers)
        assert resp.status_code == 201, resp.get_data(as_text=True)
        voucher_id = resp.get_json()['id']

        with app.test_client() as client:
            resp2 = client.post(f'/api/vouchers/{voucher_id}/approve', json={}, headers=auth_headers)
        assert resp2.status_code == 200, resp2.get_data(as_text=True)

        # Attribution now requires an explicit act, so make one before testing
        # that cancellation undoes it.
        with app.app_context():
            advance_id = SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher_id).first().id

        with app.test_client() as client:
            resp3 = client.post(
                f'/api/gold-advances/{advance_id}/allocate',
                json={'obligation_id': obligation_id, 'weight_main_karat': 30.0},
                headers=auth_headers,
            )
        assert resp3.status_code == 201, resp3.get_data(as_text=True)

        with app.app_context():
            from services.gold_allocation_service import (
                advance_remaining,
                obligation_attributed_remaining,
            )
            assert advance_remaining(SupplierGoldAdvance.query.get(advance_id)) == 0.0
            assert obligation_attributed_remaining(
                InvoiceGoldObligation.query.get(obligation_id)
            ) == 70.0

        with app.test_client() as client:
            resp4 = client.post(
                f'/api/vouchers/{voucher_id}/cancel', json={'reason': 'test'}, headers=auth_headers,
            )
        assert resp4.status_code == 200, resp4.get_data(as_text=True)

        with app.app_context():
            from services.gold_allocation_service import (
                advance_remaining,
                obligation_attributed_remaining,
            )
            advance = SupplierGoldAdvance.query.get(advance_id)
            assert GoldAllocation.query.filter_by(advance_id=advance_id).count() == 0, \
                'cancelling must free the allocation'
            assert advance_remaining(advance) == 30.0
            assert obligation_attributed_remaining(
                InvoiceGoldObligation.query.get(obligation_id)
            ) == 100.0


## NOT covered here, deliberately: a real POST /api/invoices for a 'شراء'
## invoice. In this bare test environment that request fails before the
## obligation trigger is reached — "No memo account for weight safety-net
## posting (karat 21)" — because the AccountingMapping seed for the weight
## memo account is absent, which leaves the journal entry weight-unbalanced
## and the whole request rejected with 400. Confirmed pre-existing and
## unrelated to this work: test_supplier_purchase_return_invoice.py's own
## 'شراء' invoice creation (same 'items' shape) is independently known to fail
## in the same environment (see Phase 13's closure audit in project memory).
## The invoice-side trigger is proven at the direct function-call level
## instead — TestGoldAdvancesRoutes.test_list_obligations_and_allocate above
## calls create_gold_obligations_for_invoice, and
## test_gold_allocation_service.py covers the normalizer and the eligibility
## gate — plus the call site itself was verified by reading
## routes/invoices.py's shared post-commit tail (right after is_posted=True).
