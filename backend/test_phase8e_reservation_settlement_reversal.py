"""test_phase8e_reservation_settlement_reversal.py
====================================================
Phase 8E — Office Reservation Settlement Reversal & Resettlement.

Proves the fix for the gap Phase 8A-8D found: rejecting an (unposted)
purchase invoice created by settle_office_reservation must fully undo that
settlement's accounting effects (gold_entry, weight-closing consumption,
deposit-voucher relink) before the reservation becomes resettleable —
otherwise a second settlement would double-post the purchase and
double-consume weight-closing capacity, while the original deposit voucher
stays permanently orphaned on the rejected invoice.

Fixture strategy: directly constructs, via the ORM, the exact DB state that
settle_office_reservation produces immediately after settling — rather than
driving create_office_reservation/settle_office_reservation through their
own HTTP endpoints. Those endpoints depend on a full chart-of-accounts /
office-supplier-service stack this test does not need to exercise, and
doing so was found to hit unrelated, pre-existing environment fragility
(a Postgres sequence out of sync for one helper; a bare 'sqlite://'
in-memory harness with cross-connection visibility issues for another) —
neither relevant to what this test is actually proving. Constructing the
precondition state directly is both more targeted (it isolates the
reversal/reject logic specifically) and avoids both unrelated issues.
"""
import json
import uuid
from datetime import datetime

from models import (
    Account,
    Customer,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    Office,
    OfficeReservation,
    PaymentMethod,
    Supplier,
    Voucher,
    VoucherAccountLine,
    WeightClosingOrder,
    WeightClosingExecution,
    db,
)


def _uid():
    return uuid.uuid4().hex[:8]


def _account(type_='Expense', transaction_type='cash'):
    acc = Account(
        account_number=f'TST{_uid()}', name=f'حساب اختبار {_uid()}',
        type=type_, transaction_type=transaction_type,
    )
    db.session.add(acc)
    db.session.flush()
    return acc


def _office_and_supplier():
    office_account = _account(type_='Liability', transaction_type='cash')
    office = Office(office_code=f'OFF-{_uid()}', name=f'مكتب اختبار {_uid()}', active=True)
    office.account_category_id = office_account.id
    db.session.add(office)
    db.session.flush()

    supplier = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد اختبار {_uid()}')
    db.session.add(supplier)
    db.session.flush()

    # Link them the way production does (Office.supplier_id, a real FK) so
    # ensure_office_supplier's own lookup (`if office.supplier: return`)
    # finds this supplier directly rather than attempting to INSERT a new
    # one — needed for the real settle endpoint call in the resettle test.
    office.supplier_id = supplier.id
    db.session.add(office)
    db.session.flush()

    return office, supplier, office_account


def _source_sale_invoice_with_open_order(weight_main_karat=5.0):
    """A minimal sale invoice + a WeightClosingOrder with open capacity
    (order.invoice_id is NOT NULL + UNIQUE, so a real Invoice row is
    required, but its own content is irrelevant to this test)."""
    sale_invoice = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='بيع', date=datetime.now(), total=0.0, status='unpaid',
        amount_paid=0.0, is_posted=True,
    )
    db.session.add(sale_invoice)
    db.session.flush()

    order = WeightClosingOrder(
        invoice_id=sale_invoice.id,
        order_number=f'WCO-{_uid()}',
        status='open',
        total_weight_main_karat=weight_main_karat,
        executed_weight_main_karat=0.0,
        remaining_weight_main_karat=weight_main_karat,
        close_price_per_gram=230.0,
    )
    db.session.add(order)
    db.session.flush()
    return order


def _settled_reservation_state(deposit_amount, weight_consumed, order):
    """Builds the full post-settle state a real settle_office_reservation
    call would have produced: reservation linked to purchase_invoice_a,
    a deposit voucher relinked to it, gold_entry (2 JE lines), and a
    WeightClosingExecution row consuming `weight_consumed` from `order`."""
    office, supplier, office_account = _office_and_supplier()
    purchases_account = _account(type_='Expense', transaction_type='cash')

    # Phase 9C requires payment_method_id to settle a deposit — this
    # fixture hand-constructs "as if already settled" state directly
    # (not via the real create_office_reservation endpoint, which is
    # exercised in test_phase9c_reservation_invoice_payment.py instead),
    # so it must set this explicitly to stay settleable.
    payment_method = PaymentMethod(name=f'وسيلة اختبار 8E {_uid()}', payment_type='cash')
    db.session.add(payment_method)
    db.session.flush()

    reservation = OfficeReservation(
        office_id=office.id,
        reservation_code=f'RES-{_uid()}',
        weight_grams=weight_consumed,
        weight_main_karat=weight_consumed,
        price_per_gram=230.0,
        execution_price_per_gram=230.0,
        total_amount=deposit_amount,
        paid_amount=deposit_amount,
        payment_status='paid',
        status='completed',
        payment_method_id=payment_method.id,
    )
    db.session.add(reservation)
    db.session.flush()

    invoice_a = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1,
        invoice_type='شراء', supplier_id=supplier.id, office_id=office.id,
        date=datetime.now(), total=deposit_amount, status='paid',
        amount_paid=deposit_amount, is_posted=False, gold_type='scrap',
    )
    db.session.add(invoice_a)
    db.session.flush()

    reservation.purchase_invoice_id = invoice_a.id
    db.session.add(reservation)

    # The deposit voucher: created at reservation time, already relinked to
    # the invoice by settle_office_reservation (exactly as Phase 8A traced).
    deposit_voucher = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=supplier.id,
        reference_type='invoice', reference_id=invoice_a.id,
        reference_number=str(invoice_a.id), status='approved',
        amount_cash=deposit_amount, amount_gold=0.0,
    )
    db.session.add(deposit_voucher)
    db.session.flush()
    db.session.add(VoucherAccountLine(
        voucher_id=deposit_voucher.id, account_id=office_account.id,
        line_type='debit', amount_type='cash', amount=deposit_amount,
    ))
    db.session.add(VoucherAccountLine(
        voucher_id=deposit_voucher.id, account_id=purchases_account.id,
        line_type='credit', amount_type='cash', amount=deposit_amount,
    ))

    gold_entry = JournalEntry(
        entry_number=f'WGT-{_uid()}', date=datetime.now(),
        description=f'تنفيذ حجز ذهب ({reservation.reservation_code}) - مكتب {office.name}',
        reference_type='office_reservation', reference_id=reservation.id,
        is_posted=True, posted_at=datetime.now(), posted_by='test',
    )
    db.session.add(gold_entry)
    db.session.flush()
    db.session.add(JournalEntryLine(
        journal_entry_id=gold_entry.id, account_id=purchases_account.id,
        cash_debit=deposit_amount, cash_credit=0.0,
        description='شراء ذهب تسكير - مشتريات',
    ))
    db.session.add(JournalEntryLine(
        journal_entry_id=gold_entry.id, account_id=office_account.id,
        cash_debit=0.0, cash_credit=deposit_amount,
        description='مستحق لمكتب التسكير',
    ))
    db.session.flush()

    db.session.add(WeightClosingExecution(
        order_id=order.id, source_invoice_id=invoice_a.id,
        execution_type='office_reservation', weight_main_karat=weight_consumed,
        price_per_gram=230.0, journal_entry_id=gold_entry.id,
    ))
    order.executed_weight_main_karat = (order.executed_weight_main_karat or 0.0) + weight_consumed
    order.remaining_weight_main_karat = max(
        (order.total_weight_main_karat or 0.0) - order.executed_weight_main_karat, 0.0
    )
    order.status = 'closed' if order.remaining_weight_main_karat <= 0.0001 else 'partially_closed'
    db.session.add(order)

    db.session.commit()
    return {
        'reservation_id': reservation.id,
        'invoice_a_id': invoice_a.id,
        'gold_entry_id': gold_entry.id,
        'deposit_voucher_id': deposit_voucher.id,
        'purchases_account_id': purchases_account.id,
        'office_account_id': office_account.id,
        'office_id': office.id,
    }


class TestRejectReversesReservationSettlement:
    def test_reject_reverses_gold_entry_weight_consumption_and_voucher_relink(self, auth_headers):
        from app import app
        with app.app_context():
            client = app.test_client()
            # Capacity matches consumption exactly (no leftover): these tests
            # commit to the real dev DB with no rollback, and
            # _auto_consume_weight_closing's own FIFO query is global across
            # ALL open/partially_closed orders — any leftover capacity here
            # would be silently stolen by a later test's own consumption.
            order = _source_sale_invoice_with_open_order(weight_main_karat=2.5)
            state = _settled_reservation_state(
                deposit_amount=575.0, weight_consumed=2.5, order=order,
            )

            resp = client.post(
                f'/api/invoices/{state["invoice_a_id"]}/reject',
                headers=auth_headers, json={},
            )
            assert resp.status_code == 200, resp.data

            db.session.expire_all()

            assert WeightClosingExecution.query.filter_by(
                source_invoice_id=state['invoice_a_id']
            ).count() == 0, "the execution row consumed by the rejected settlement must be reversed"

            refreshed_order = WeightClosingOrder.query.get(order.id)
            assert refreshed_order.executed_weight_main_karat == 0.0, (
                "weight-closing capacity consumed by the rejected settlement must be restored"
            )
            assert refreshed_order.status == 'open'

            reversal_entries = JournalEntry.query.filter_by(
                reference_type='office_reservation_settlement_reversal',
                reference_id=state['invoice_a_id'],
            ).all()
            assert len(reversal_entries) == 1, "exactly one reversing JE for gold_entry_a"

            original_lines = JournalEntryLine.query.filter_by(
                journal_entry_id=state['gold_entry_id']
            ).all()
            assert len(original_lines) == 2, "gold_entry_a itself must survive untouched, for audit"

            reversal_lines = JournalEntryLine.query.filter_by(
                journal_entry_id=reversal_entries[0].id
            ).all()
            assert len(reversal_lines) == 2
            for orig in original_lines:
                mirror = next(l for l in reversal_lines if l.account_id == orig.account_id)
                assert (mirror.cash_debit or 0.0) == (orig.cash_credit or 0.0)
                assert (mirror.cash_credit or 0.0) == (orig.cash_debit or 0.0)

            refreshed_voucher = Voucher.query.get(state['deposit_voucher_id'])
            assert refreshed_voucher.reference_type == 'office_reservation'
            assert refreshed_voucher.reference_id == state['reservation_id']

            refreshed_reservation = OfficeReservation.query.get(state['reservation_id'])
            assert refreshed_reservation.purchase_invoice_id is None
            assert refreshed_reservation.status == 'pending'

            # Test-only cleanup: the reversal above correctly re-opens this
            # order's capacity (proving the fix), but these tests commit to
            # the real dev DB with no rollback, and weight-closing's own
            # consumption query is a global FIFO pool across every
            # open/partially_closed order, unscoped to any one reservation
            # (pre-existing, unrelated production behavior). Left 'open',
            # it would leak into a LATER, unrelated test's own consumption.
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).update({'status': 'closed'}, synchronize_session=False)
            db.session.commit()

    def test_reject_is_idempotent_when_called_again(self, auth_headers):
        """Calling the reversal path twice (e.g. a retried request) must be
        a safe no-op the second time, not double-reverse or error."""
        from app import app
        with app.app_context():
            client = app.test_client()
            # Capacity matches consumption exactly — see the comment on the
            # same pattern in the first test above.
            order = _source_sale_invoice_with_open_order(weight_main_karat=1.0)
            state = _settled_reservation_state(
                deposit_amount=1000.0, weight_consumed=1.0, order=order,
            )

            first = client.post(
                f'/api/invoices/{state["invoice_a_id"]}/reject',
                headers=auth_headers, json={},
            )
            assert first.status_code == 200, first.data

            second = client.post(
                f'/api/invoices/{state["invoice_a_id"]}/reject',
                headers=auth_headers, json={},
            )
            assert second.status_code == 200, second.data

            db.session.expire_all()
            reversal_entries = JournalEntry.query.filter_by(
                reference_type='office_reservation_settlement_reversal',
                reference_id=state['invoice_a_id'],
            ).all()
            assert len(reversal_entries) == 1, "a second reject must not create a second reversal"

            refreshed_order = WeightClosingOrder.query.get(order.id)
            assert refreshed_order.executed_weight_main_karat == 0.0

            # Test-only cleanup — see the comment on the same step in the
            # first test above.
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).update({'status': 'closed'}, synchronize_session=False)
            db.session.commit()

    def test_reject_does_not_touch_unrelated_invoices(self, auth_headers):
        """A plain, non-reservation invoice rejection must be completely
        unaffected by this change — no reversal machinery should engage
        for it at all."""
        from app import app
        with app.app_context():
            client = app.test_client()
            customer = Customer(customer_code=f'CUST-{_uid()}', name='عميل اختبار')
            db.session.add(customer)
            db.session.flush()
            plain_invoice = Invoice(
                invoice_type_id=int(_uid(), 16) % 900000 + 1,
                invoice_type='بيع', customer_id=customer.id, date=datetime.now(),
                total=100.0, status='unpaid', amount_paid=0.0, is_posted=False,
            )
            db.session.add(plain_invoice)
            db.session.commit()
            plain_invoice_id = plain_invoice.id

            resp = client.post(
                f'/api/invoices/{plain_invoice_id}/reject', headers=auth_headers, json={},
            )
            assert resp.status_code == 200, resp.data

            refreshed = Invoice.query.get(plain_invoice_id)
            assert refreshed.status == 'rejected'
            assert JournalEntry.query.filter_by(
                reference_type='office_reservation_settlement_reversal',
                reference_id=plain_invoice_id,
            ).count() == 0

    def test_resettle_after_reject_produces_exactly_one_clean_settlement(self, auth_headers):
        """Closes the one gap left open after the reversal-only tests above:
        actually calls the real POST /office-reservations/<id>/settle
        endpoint a SECOND time (not a simulation) after reject, and proves
        the round-trip end to end — exactly one live gold_entry, the weight
        consumed exactly once (not twice), and the SAME deposit voucher
        relinked to the new invoice. No new production code in this test —
        pure verification of the fix already implemented and covered above.
        """
        from app import app
        with app.app_context():
            client = app.test_client()

            # settle_office_reservation resolves the purchases account by
            # account_number ('512' or '511') independently of anything
            # this test's own fixture wires up for gold_entry_a — the real
            # endpoint needs it to exist for the SECOND (real) settle call.
            if not Account.query.filter_by(account_number='512').first():
                db.session.add(Account(
                    account_number='512', name='مشتريات ذهب كسر',
                    type='Expense', transaction_type='cash',
                ))
                db.session.commit()

            order = _source_sale_invoice_with_open_order(weight_main_karat=5.0)
            state = _settled_reservation_state(
                deposit_amount=575.0, weight_consumed=2.5, order=order,
            )
            reservation_id = state['reservation_id']

            reject_resp = client.post(
                f'/api/invoices/{state["invoice_a_id"]}/reject',
                headers=auth_headers, json={},
            )
            assert reject_resp.status_code == 200, reject_resp.data
            db.session.expire_all()

            # Any leftover open/partially_closed order from an earlier test
            # (in this file or another run in the same process) would be
            # consumed ahead of this test's own order by the global FIFO
            # match in _auto_consume_weight_closing — force a clean pool
            # immediately before the resettle this test is actually
            # asserting on. See the fixture-leakage note further up.
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).filter(WeightClosingOrder.id != order.id).update(
                {'status': 'closed'}, synchronize_session=False
            )
            db.session.commit()

            settle_resp_b = client.post(
                f'/api/office-reservations/{reservation_id}/settle',
                headers=auth_headers,
                json={'execution_price_per_gram': 230.0},
            )
            assert settle_resp_b.status_code == 200, settle_resp_b.data
            invoice_b_id = json.loads(settle_resp_b.data)['purchase_invoice_id']
            assert invoice_b_id != state['invoice_a_id']

            # gold_entry_a is intentionally NEVER deleted (it stays for audit,
            # per the orchestrator's own design) — so a raw count of entries
            # matching this description will always be 2 after a resettle
            # (gold_entry_a + gold_entry_b), regardless of correctness. The
            # real invariant is the NET effect on the account they share
            # (office.account_category_id): gold_entry_a's credit is
            # cancelled by its own reversal's debit, leaving exactly
            # gold_entry_b's credit as the only live effect.
            all_office_account_lines = (
                JournalEntryLine.query
                .filter_by(account_id=state['office_account_id'])
                .join(JournalEntry)
                .filter(JournalEntry.reference_id.in_([
                    reservation_id, state['invoice_a_id'],
                ]))
                .all()
            )
            net_on_office_account = sum(
                (l.cash_credit or 0.0) - (l.cash_debit or 0.0) for l in all_office_account_lines
            )
            assert net_on_office_account == 575.0, (
                "net effect on the office account across gold_entry_a + its "
                "reversal + gold_entry_b must equal exactly one settlement's "
                f"worth (575.0), got {net_on_office_account} from "
                f"{len(all_office_account_lines)} lines — a value of 1150.0 "
                "would mean the purchase was posted twice."
            )

            live_gold_entries = (
                JournalEntry.query
                .filter_by(reference_type='office_reservation', reference_id=reservation_id)
                .filter(JournalEntry.description.like('تنفيذ حجز ذهب%'))
                .filter(JournalEntry.is_deleted == False)
                .all()
            )
            assert state['gold_entry_id'] in [e.id for e in live_gold_entries], (
                "gold_entry_a must still be visible — never deleted, only reversed"
            )
            assert len(live_gold_entries) == 2, (
                "gold_entry_a (kept for audit) + gold_entry_b (the new settlement)"
            )

            refreshed_order = WeightClosingOrder.query.get(order.id)
            assert refreshed_order.executed_weight_main_karat == 2.5, (
                "weight must be consumed exactly once across reject+resettle, "
                f"got {refreshed_order.executed_weight_main_karat}"
            )

            refreshed_voucher = Voucher.query.get(state['deposit_voucher_id'])
            assert refreshed_voucher.reference_type == 'invoice'
            assert refreshed_voucher.reference_id == invoice_b_id

            invoice_b = Invoice.query.get(invoice_b_id)
            assert invoice_b.status == 'paid'
            assert invoice_b.amount_paid == 575.0

            # Test-only cleanup — see the note above.
            WeightClosingOrder.query.filter(
                WeightClosingOrder.status.in_(['open', 'partially_closed'])
            ).update({'status': 'closed'}, synchronize_session=False)
            db.session.commit()
