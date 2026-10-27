"""A reservation's deposit its purchase's posting paid again, set right (the owner, 27 Oct 2026: «نفذ»).

The deposit voucher paid the deposit when the reservation was made. Executed,
the reservation showed it on its purchase as a payment linked to that voucher
(Phase 9C), and the purchase's posting wrote that payment an entry of its own
(PAY-<invoice>-ALL) -- a second payment out of the safe. The cause is shut
(posting_routes._carried_by_its_voucher); this sets right what it wrote. On
the 27 Oct backup, two:

- RES-...-0032, purchase 3090, 0.05: the voucher stands, so the second entry
  is reversed. It credited the main cash, so its reversal debits the
  temporary cash box (the owner's rule, services/repair/entries).
- RES-...-0038, purchase 3501, 53,123.62: the owner cancelled the voucher to
  undo the second, so the posting's entry is the one payment left -- but the
  payment row still named the cancelled voucher, and the purchase read
  unpaid. The row gets a voucher on that entry, as posting writes one
  (LINK-001): no entry, no amount moves.

Only a posting entry that carries that payment alone is touched; anything else
is said, not guessed. dry_run (the default) writes nothing.
"""
import json
import re

from models import AuditLog, Invoice, InvoicePayment, JournalEntry, Voucher, db
from services.repair.entries import reverse_entry, reversed_already

POSTING_REF = 'invoice_payments'
_PAYMENT_IDS = re.compile(r'\(دفعات: ([\d,]+)\)')


def _payment_ids(entry):
    found = _PAYMENT_IDS.search(entry.description or '')
    return [int(x) for x in found.group(1).split(',')] if found else []


def _paid_twice():
    """(payment, its voucher, the posting entry that paid it again)."""
    cases = []
    for entry in JournalEntry.query.filter_by(reference_type=POSTING_REF, is_deleted=False).order_by(JournalEntry.id):
        if reversed_already(entry.id):
            continue
        for pid in _payment_ids(entry):
            pay = InvoicePayment.query.get(pid)
            voucher = Voucher.query.get(pay.source_voucher_id) if pay and pay.source_voucher_id else None
            if voucher is None or not voucher.journal_entry_id or voucher.journal_entry_id == entry.id:
                continue
            own = JournalEntry.query.get(voucher.journal_entry_id)
            if own is not None and not own.is_deleted:
                cases.append((pay, voucher, entry))
    return cases


def set_deposits_paid_twice_right(*, by: str, now, dry_run: bool = True) -> dict:
    from accounting.invoice_payment_voucher import (
        approve_invoice_payment_voucher, build_invoice_payment_voucher, invoice_payment_party,
    )
    from services.invoice_payment_state_service import InvoicePaymentStateService

    reversed_, relinked, refused = [], [], []
    for pay, voucher, entry in _paid_twice():
        case = {'invoice_id': pay.invoice_id, 'payment_id': pay.id, 'amount': round(float(pay.amount or 0.0), 2),
                'voucher': voucher.voucher_number, 'voucher_status': voucher.status, 'entry': entry.entry_number}
        if _payment_ids(entry) != [pay.id]:
            refused.append({**case, 'why': 'the posting entry carries other payments'})
            continue
        invoice = Invoice.query.get(pay.invoice_id)
        if voucher.status == 'cancelled':
            relinked.append(case)
            if not dry_run:
                safe_line = next(l for l in entry.lines if not l.is_deleted and float(l.cash_credit or 0.0) > 0)
                new = build_invoice_payment_voucher(
                    invoice, pay, payment_method_id=pay.payment_method_id or 0,
                    safe_account_id=safe_line.account_id, party=invoice_payment_party(invoice),
                    direction='out', created_by=by)
                approve_invoice_payment_voucher(new, entry, by)
                db.session.flush()
                InvoicePaymentStateService().recompute(invoice)
                case['new_voucher'] = new.voucher_number
        else:
            reversed_.append(case)
            if not dry_run:
                rev = reverse_entry(entry, by=by, now=now, substitute=True, safe_rows=True,
                                    reason=f'دفعه سند العربون {voucher.voucher_number} من قبل')
                case['reversal'] = rev.entry_number

    plan = {'reversed': reversed_, 'relinked': relinked, 'refused': refused}
    if (reversed_ or relinked) and not dry_run:
        db.session.add(AuditLog(user_name=by, action='repair_deposit_paid_twice', entity_type='invoice_payment',
                                entity_id=(reversed_ + relinked)[0]['payment_id'], success=True,
                                details=json.dumps(plan, ensure_ascii=False, default=str)))
        db.session.flush()
    return plan
