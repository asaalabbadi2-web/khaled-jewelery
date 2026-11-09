"""A payment-method correction written backwards, set right (the owner, 9 Nov 2026: «أ»).

Before the fix in routes/invoices.py, «تصحيح وسيلة الدفع» wrote «credit the
old safe, debit the new» for every payment: right for money received,
backwards for money paid out. On the 9 Nov backup one such entry stands:
JE-2026-07425, 494.5 paid the Dewan (purchase 215) put right from the cash
box to the transfer -- it credited the main cash box again and debited the
Riyadh bank, the books 989 off in both, their safe rows right.

Each one found is set right by entries, the wrong one untouched:
- its reversal ('journal_entry_reversal' -> it), dated as it;
- the correction as it should have been -- the old safe debited, the new
  one credited -- a 'payment_method_correction' of the same payment.
No safe row: the rows were right all along.

The main cash box and the Riyadh bank are protected since the 3 Oct
reconciliation (services/repair/entries.py). This error came after it, in
them: the owner chose to set them right themselves («أ»), so only the
accounts the wrong entry touched are allowed, for these entries alone.

Found: a 'payment_method_correction' entry, not reversed, of a payment whose
own records say it was paid out ('out'), that debits the safe of the
payment's present method. dry_run (the default) writes nothing.
"""
from __future__ import annotations

import json

from models import AuditLog, InvoicePayment, JournalEntry, PaymentMethod, SafeBox, db
from services.payment_direction import payment_direction
from services.repair.entries import reversed_already, reverse_entry, write_entry

CORRECTION = 'payment_method_correction'


def _live(entry):
    return [l for l in entry.lines if not getattr(l, 'is_deleted', False)]


def reversed_corrections() -> list:
    """(the wrong entry, its payment, the old safe's account, the new one's, the amount)."""
    found = []
    for entry in (JournalEntry.query.filter_by(reference_type=CORRECTION, is_deleted=False)
                  .order_by(JournalEntry.id)):
        if reversed_already(entry.id):
            continue
        payment = db.session.get(InvoicePayment, entry.reference_id) if entry.reference_id else None
        method = db.session.get(PaymentMethod, payment.payment_method_id) if payment else None
        safe = db.session.get(SafeBox, method.default_safe_box_id) if method and method.default_safe_box_id else None
        if safe is None or payment_direction(payment) != 'out':
            continue
        lines = _live(entry)
        debited = [l for l in lines if l.account_id == safe.account_id and float(l.cash_debit or 0) > 0.005]
        credited = [l for l in lines if float(l.cash_credit or 0) > 0.005 and l.account_id != safe.account_id]
        if len(debited) != 1 or len(credited) != 1:
            continue                       # not the shape it wrote: said by nothing, touched by nothing
        amount = round(float(debited[0].cash_debit), 2)
        if abs(amount - round(float(credited[0].cash_credit), 2)) > 0.005:
            continue
        found.append((entry, payment, credited[0].account_id, safe.account_id, amount))
    return found


def set_reversed_corrections_right(*, by: str, now, dry_run: bool = True) -> dict:
    done = []
    for entry, payment, old_account, new_account, amount in reversed_corrections():
        item = {'entry': entry.entry_number, 'payment_id': payment.id, 'invoice_id': payment.invoice_id,
                'amount': amount, 'old_account_id': old_account, 'new_account_id': new_account}
        if not dry_run:
            allowed = frozenset({old_account, new_account})
            reversal = reverse_entry(entry, by=by, now=now, allow_protected=allowed,
                                     reason='تصحيح وسيلة دفع صادرة كُتب معكوسًا (قرار المالك، 9 نوفمبر)')
            right = write_entry(
                date=entry.date,
                description=(f'إعادة تصنيف صحيحة لدفعة #{payment.id} الصادرة ({amount:.2f}): '
                             f'ترجع إلى الخزينة القديمة وتخرج من الجديدة -- بدل {entry.entry_number}'),
                reference_type=CORRECTION, reference_id=payment.id, reference_number=entry.entry_number,
                lines=[{'account_id': old_account, 'cash_debit': amount, 'description': f'رجوع دفعة #{payment.id}'},
                       {'account_id': new_account, 'cash_credit': amount, 'description': f'خروج دفعة #{payment.id}'}],
                by=by, now=now, prefix='COR', safe_rows=False, allow_protected=allowed)
            db.session.add(AuditLog(user_name=by, action='repair_reversed_method_correction',
                                    entity_type='JournalEntry', entity_id=entry.id,
                                    entity_number=entry.entry_number,
                                    details=json.dumps({**item, 'reversal': reversal.entry_number,
                                                        'right': right.entry_number}, ensure_ascii=False)))
            db.session.flush()
            item.update(reversal=reversal.entry_number, right=right.entry_number)
        done.append(item)
    return {'corrections': done, 'count': len(done), 'dry_run': dry_run}
