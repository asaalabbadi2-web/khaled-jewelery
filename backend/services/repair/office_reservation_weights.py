"""The old office reservations' gold came from a purchase, not from our scrap stock
(stage-4 item 8; the owner, 11 Oct 2026: «اصلحها»).

Until 1 Oct 2026 an office reservation recorded the office's gold -- bought
from it, left with it, ours -- as debit the office's weight account, credit the
scrap stock (71310): gold leaving a stock it never entered. 28 entries on the
10 Oct copy, about 6,083 g at the main karat, which alone put the scrap stock
below zero. The other side is the purchases' weight twin, 7512 «مشتريات ذهب
كسر من العملاء وزني», as the cash side is 512 (routes/office_reservations.py
writes it so since 1 Oct).

Each entry gets one transfer, dated as it and carrying its weights karat by
karat: debit 71310, credit 7512 -- never an edit of the posted entry. No cash
column moves. Idempotent: an entry with a posted transfer is not taken again.
dry_run (the default) writes nothing and says what it would do.
"""
import json

from models import Account, AuditLog, JournalEntry, JournalEntryLine, db
from pricing.gold_price_service import get_main_karat
from services.repair.entries import write_entry

TRANSFER = 'office_reservation_weight_transfer'
SCRAP_STOCK = '71310'
PURCHASES_TWIN = '7512'
KARATS = ('18k', '21k', '22k', '24k')


class NotAsMeasured(ValueError):
    pass


def _account(number) -> Account:
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        raise NotAsMeasured(f'account {number} not found')
    return a


def _transferred(entry_id: int) -> bool:
    return JournalEntry.query.filter(
        JournalEntry.reference_type == TRANSFER, JournalEntry.reference_id == entry_id,
        JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False)).first() is not None


def transfer_office_reservation_weights(*, by: str, now, dry_run: bool = True) -> dict:
    scrap, twin = _account(SCRAP_STOCK), _account(PURCHASES_TWIN)
    entries = (JournalEntry.query
               .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
               .filter(JournalEntry.reference_type == 'office_reservation',
                       JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False),
                       JournalEntryLine.account_id == scrap.id, JournalEntryLine.is_deleted.is_(False))
               .distinct().order_by(JournalEntry.date, JournalEntry.id).all())
    plan, skipped, grams_main = [], [], 0.0
    for entry in entries:
        if _transferred(entry.id):
            continue
        lines = [l for l in entry.lines if l.account_id == scrap.id and not l.is_deleted]
        # What left the scrap stock, karat by karat (credit - debit).
        out = {k: round(sum(float(getattr(l, f'credit_{k}') or 0) - float(getattr(l, f'debit_{k}') or 0)
                            for l in lines), 6) for k in KARATS}
        if any(v < -0.0005 for v in out.values()):
            raise NotAsMeasured(f'entry {entry.entry_number}: puts gold into {SCRAP_STOCK} ({out})')
        if all(abs(v) < 0.0005 for v in out.values()):
            skipped.append({'entry_number': entry.entry_number, 'karats': out})   # a rounding remainder
            continue
        main = sum(v * int(k[:-1]) / get_main_karat() for k, v in out.items())
        grams_main += main
        step = {'entry_id': entry.id, 'entry_number': entry.entry_number, 'date': entry.date,
                'reservation_id': entry.reference_id, 'karats': {k: v for k, v in out.items() if v},
                'main_karat_grams': round(main, 3)}
        plan.append(step)
        if dry_run:
            continue
        weight_type = lines[0].weight_type
        write_entry(
            date=entry.date,
            description=f'تصحيح: وزن حجز المكتب من توأم المشتريات لا من مخزون الكسر ({entry.entry_number})',
            reference_type=TRANSFER, reference_id=entry.id, reference_number=entry.entry_number,
            lines=[
                {'account_id': scrap.id, 'description': 'إعادة ذهب لم يخرج من مخزون الكسر',
                 'weight_type': weight_type, **{f'debit_{k}': v for k, v in out.items() if v}},
                {'account_id': twin.id, 'description': 'ذهب حجز المكتب من الشراء',
                 'weight_type': weight_type, **{f'credit_{k}': v for k, v in out.items() if v}},
            ],
            by=by, now=now, prefix='COR', safe_rows=False,
        )
    if plan and not dry_run:
        db.session.add(AuditLog(user_name=by, action='office_reservation_weight_transfer', entity_type='journal_entry',
                                entity_id=plan[0]['entry_id'], success=True,
                                details=json.dumps({'entries': len(plan), 'main_karat_grams': round(grams_main, 3),
                                                    'at': now}, ensure_ascii=False, default=str)))
        db.session.flush()
    return {'entries': plan, 'count': len(plan), 'main_karat_grams': round(grams_main, 3), 'skipped': skipped}
