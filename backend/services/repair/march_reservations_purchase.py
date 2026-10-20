"""Two office reservations paid in cash in March, whose gold the books then owed
back to the office (stage-4 item 21; found 11 Oct 2026 by ADR-042 phase 2).

Reservations 8 and 43 (مكاتب تسكير فورية واشخاص, 52,478 + 63,900) were paid by
voucher in March (PV-2026-00101, PV-2026-00112). Their gold -- 185.4 g of 24k,
211.886 g at the main karat -- reached the main scrap safe by AV-2026-00012
(JE-2026-00939, 18 March): debit the safe, credit the office's weight account
72100021, which had never been debited. So the books owe the office 185.4 g
it was paid for, and the scrap pool reads 211.886 g short. The price reached
purchases only on 29 July, by a manual entry «تسوية حجز سابق» (JE-2026-04561:
debit 512, credit the office 116,378) -- a purchase with no gold, in a month
the gold did not come.

Two entries, never an edit of a posted one:

  the purchase, dated as the transfer -- debit the office's weight account,
      credit the purchases' weight twin 7512, karat by karat; debit 512,
      credit the office's cash account, the price: what an office reservation
      writes since 1 Oct (routes/office_reservations.py)
  the reversal of the manual entry, dated as it

The office ends owing nothing in gold and nothing in cash, as before; the
price sits in March with its gold, and the moving average (services/gold_cost)
reads a purchase at its price. Idempotent; dry_run (the default) writes
nothing and says what it would do.
"""
import json

from models import Account, AuditLog, JournalEntry, JournalEntryLine, OfficeReservation, db
from pricing.gold_price_service import get_main_karat
from services.repair.entries import write_entry

PURCHASE = 'office_reservation_purchase_recognized'
PURCHASES, PURCHASES_TWIN = '512', '7512'
KARATS = ('18k', '21k', '22k', '24k')


class NotAsMeasured(ValueError):
    pass


def _account(number) -> Account:
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        raise NotAsMeasured(f'account {number} not found')
    return a


def _entry(number) -> JournalEntry:
    e = JournalEntry.query.filter_by(entry_number=number).first()
    if e is None or not e.is_posted or e.is_deleted:
        raise NotAsMeasured(f'entry {number} not found posted')
    return e


def _live(entry):
    return [l for l in entry.lines if not l.is_deleted]


def record_march_reservations_purchase(*, by: str, now, dry_run: bool = True,
                                       transfer_entry='JE-2026-00939', settlement_entry='JE-2026-04561',
                                       office_weight='72100021', office_cash='21000020',
                                       reservation_ids=(8, 43)) -> dict:
    transfer, settled = _entry(transfer_entry), _entry(settlement_entry)
    weight, cash = _account(office_weight), _account(office_cash)
    purchases, twin = _account(PURCHASES), _account(PURCHASES_TWIN)

    done = JournalEntry.query.filter(JournalEntry.reference_type == PURCHASE,
                                     JournalEntry.reference_id == transfer.id,
                                     JournalEntry.is_deleted.is_(False)).first()
    if done is not None:
        return {'done': True, 'entries': [], 'grams_24k': 0.0, 'amount': 0.0}

    # The gold the transfer credited to the office, karat by karat ...
    credited = {k: round(sum(float(getattr(l, f'credit_{k}') or 0) - float(getattr(l, f'debit_{k}') or 0)
                             for l in _live(transfer) if l.account_id == weight.id), 6) for k in KARATS}
    if any(v < 0 for v in credited.values()) or not any(credited.values()):
        raise NotAsMeasured(f'{transfer_entry} does not credit {office_weight} with gold ({credited})')
    # ... is all the office's weight account holds: nothing has moved it since.
    held = {k: round(sum(float(getattr(l, f'debit_{k}') or 0) - float(getattr(l, f'credit_{k}') or 0)
                         for l in JournalEntryLine.query.join(JournalEntry)
                         .filter(JournalEntryLine.account_id == weight.id, JournalEntryLine.is_deleted.is_(False),
                                 JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False))), 6)
            for k in KARATS}
    if any(abs(held[k] + credited[k]) > 0.0005 for k in KARATS):
        raise NotAsMeasured(f'{office_weight} holds {held}, not the {credited} credited by {transfer_entry}')

    # The price: the manual entry, debit 512 / credit the office -- and the reservations' amounts.
    lines = _live(settled)
    amount = round(sum(float(l.cash_debit or 0) for l in lines if l.account_id == purchases.id), 2)
    owed = round(sum(float(l.cash_credit or 0) for l in lines if l.account_id == cash.id), 2)
    if amount <= 0 or abs(amount - owed) > 0.005 or len(lines) != 2:
        raise NotAsMeasured(f'{settlement_entry} is not debit {PURCHASES} / credit {office_cash} ({amount} / {owed})')
    if reservation_ids:
        total = sum(float(r.total_amount or 0) for r in
                    OfficeReservation.query.filter(OfficeReservation.id.in_(reservation_ids)).all())
        if abs(total - amount) > 0.01:
            raise NotAsMeasured(f'reservations {reservation_ids} total {total}, not {amount}')

    plan = {'done': False, 'grams_24k': credited['24k'], 'karats': {k: v for k, v in credited.items() if v},
            'grams_main': round(sum(v * int(k[:-1]) / get_main_karat() for k, v in credited.items()), 3),
            'amount': amount, 'purchase_date': transfer.date, 'reversal_date': settled.date, 'entries': []}
    if dry_run:
        return plan

    weight_type = next(l.weight_type for l in _live(transfer) if l.account_id == weight.id)
    purchase = write_entry(
        date=transfer.date,
        description=f'تصحيح: ذهب حجزي المكتب المدفوعين نقدًا شراءٌ بثمنه، لا دين للمكتب ({transfer_entry})',
        reference_type=PURCHASE, reference_id=transfer.id, reference_number=transfer_entry,
        lines=[
            {'account_id': weight.id, 'description': 'ذهب الحجز وصل، لا دين للمكتب', 'weight_type': weight_type,
             **{f'debit_{k}': v for k, v in credited.items() if v}},
            {'account_id': twin.id, 'description': 'ذهب الحجز من الشراء', 'weight_type': weight_type,
             **{f'credit_{k}': v for k, v in credited.items() if v}},
            {'account_id': purchases.id, 'description': 'ثمن ذهب الحجز', 'cash_debit': amount},
            {'account_id': cash.id, 'description': 'المدفوع مقدمًا للمكتب', 'cash_credit': amount},
        ],
        by=by, now=now, prefix='COR', safe_rows=False,
    )
    reversal = write_entry(
        date=settled.date,
        description=f'عكس {settlement_entry}: ثمن الحجزين قُيّد بتاريخ وصول ذهبهما ({purchase.entry_number})',
        reference_type='journal_entry_reversal', reference_id=settled.id, reference_number=settlement_entry,
        lines=[
            {'account_id': cash.id, 'description': f'عكس {settlement_entry}', 'cash_debit': amount},
            {'account_id': purchases.id, 'description': f'عكس {settlement_entry}', 'cash_credit': amount},
        ],
        by=by, now=now, prefix='COR', safe_rows=False,
    )
    plan['entries'] = [purchase.entry_number, reversal.entry_number]
    db.session.add(AuditLog(user_name=by, action=PURCHASE, entity_type='journal_entry', entity_id=purchase.id,
                            success=True, details=json.dumps({**plan, 'at': now}, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
