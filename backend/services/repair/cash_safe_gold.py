"""The gold an older writer left on the main cash box, moved to the purchases (the owner, 14 Nov 2026).

«راجع صندوق النقدية المالي عليه وزن قديم» -- «ابنه، نعم اسمح». A customer's
purchase of 17 Feb 2026 (JE-2026-00066, «شراء من عميل» #1: 98.26 g of 24k for
54,956.82 in cash) debited the gold to the scrap safe and credited it to
«صندوق النقدية الرئيسي وزني» -- «دفع وزني - شراء عيار 24» -- where today's
writer credits the purchases' weight twin. The code that wrote it is gone; the
line stayed, and the cash box read -98.26 g.

One entry, dated as the purchase, never an edit of a posted one: debit the
cash box's weight twin and credit the purchases' weight twin with the line's
own grams, karat by karat and the main-karat weight -- every figure read from
the line. Refused, writing nothing, when the entry is not a posted customer
purchase, when it has not exactly one gram line on a cash or bank safe's
twin, when that line carries riyals or debits grams, or when anything else
moved the twin (its balance is not that line's alone); a second run finds it
done. The guard (cash_safe_gold_guard) writes it: it brings the twin back to
zero.
"""
from __future__ import annotations

import json

from models import Account, AuditLog, Invoice, JournalEntry, JournalEntryLine, SafeBox, db
from services.repair.entries import write_entry

MOVED = 'cash_safe_gold_moved'
COLUMNS = ('18k', '21k', '22k', '24k', 'weight')
EPS = 0.0005


class NotAsFound(ValueError):
    pass


def _twins_of_cash_safes() -> dict:
    """{weight twin id: safe name} of every cash or bank safe."""
    rows = (db.session.query(Account.memo_account_id, SafeBox.name).join(SafeBox, SafeBox.account_id == Account.id)
            .filter(SafeBox.safe_type.in_(('cash', 'bank')), Account.memo_account_id.isnot(None)).all())
    return {int(t): n for t, n in rows}


def _balance(account_id) -> dict:
    out = dict.fromkeys(COLUMNS, 0.0)
    for line in (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                 .filter(JournalEntryLine.account_id == account_id, JournalEntryLine.is_deleted.isnot(True),
                         JournalEntry.is_deleted.isnot(True))):
        for c in COLUMNS:
            out[c] += float(getattr(line, f'debit_{c}') or 0.0) - float(getattr(line, f'credit_{c}') or 0.0)
    return out


def purchases_weight_twin() -> Account:
    """The purchases' weight twin a customer's purchase credits today: the
    weight twin of the scrap purchases' role (ADR-046)."""
    from accounting.mappings import get_account_id_for_mapping
    found = get_account_id_for_mapping('شراء من عميل', 'purchases_gold_scrap')
    account = db.session.get(Account, found) if found else None
    twin = db.session.get(Account, account.memo_account_id) if account is not None and account.memo_account_id else None
    if twin is None or not twin.tracks_weight:
        raise NotAsFound('purchases_gold_scrap: no mapped account with a weight twin')
    return twin


def move(*, by: str, now, entry_number: str = 'JE-2026-00066', to_account: Account | None = None) -> dict:
    """Write the move; the caller commits (the CLI rolls back a dry run)."""
    entry = JournalEntry.query.filter_by(entry_number=entry_number).one_or_none()
    if entry is None or not entry.is_posted or entry.is_deleted:
        raise NotAsFound(f'{entry_number}: no posted entry')
    done = JournalEntry.query.filter(JournalEntry.reference_type == MOVED, JournalEntry.reference_id == entry.id,
                                     JournalEntry.is_deleted.isnot(True)).first()
    if done is not None:
        return {'already': True, 'entry': done.entry_number}
    invoice = db.session.get(Invoice, entry.reference_id) if entry.reference_type == 'invoice' else None
    if invoice is None or invoice.invoice_type != 'شراء من عميل':
        raise NotAsFound(f'{entry_number}: not the entry of a customer purchase')
    twins = _twins_of_cash_safes()
    on_safe = [l for l in entry.lines if not l.is_deleted and l.account_id in twins
               and any(abs(float(getattr(l, f'{s}_{c}') or 0.0)) > EPS for s in ('debit', 'credit') for c in COLUMNS)]
    if len(on_safe) != 1:
        raise NotAsFound(f'{entry_number}: {len(on_safe)} gram lines on a cash safe, not one')
    [line] = on_safe
    if float(line.cash_debit or 0.0) or float(line.cash_credit or 0.0) or \
            any(float(getattr(line, f'debit_{c}') or 0.0) for c in COLUMNS):
        raise NotAsFound(f'{entry_number}: its cash safe line is not grams credited alone')
    grams = {c: float(getattr(line, f'credit_{c}') or 0.0) for c in COLUMNS}
    held = _balance(line.account_id)
    if any(abs(held[c] + grams[c]) > EPS for c in COLUMNS):
        raise NotAsFound(f'«{twins[line.account_id]}»: its weight balance {held} is not that line\'s alone')
    to = to_account or purchases_weight_twin()

    lines = [{'account_id': line.account_id, 'description': 'إعادة ذهب الشراء من الصندوق النقدي',
              **{f'debit_{c}': v for c, v in grams.items() if v}},
             {'account_id': to.id, 'description': 'ذهب الشراء على المشتريات، كما يكتبه الشراء اليوم',
              **{f'credit_{c}': v for c, v in grams.items() if v}}]
    posted = write_entry(
        date=entry.date, reference_type=MOVED, reference_id=entry.id, reference_number=entry_number,
        description=(f'تصحيح: ذهب شراء #{invoice.invoice_type_id} على المشتريات لا على «{twins[line.account_id]}» '
                     f'— الصندوق النقدي لا يحمل ذهبًا (المالك، 14 نوفمبر 2026)'),
        lines=lines, by=by, now=now, entry_type='تصحيح', allow_protected={line.account_id, to.id})
    after = _balance(line.account_id)
    if any(abs(after[c]) > EPS for c in COLUMNS):
        raise NotAsFound(f'«{twins[line.account_id]}» after the move: {after}, not zero')
    result = {'entry': posted.entry_number, 'date': entry.date.date().isoformat(), 'from': twins[line.account_id],
              'to': to.account_number, 'grams': {c: round(v, 6) for c, v in grams.items() if v}}
    AuditLog.log_action(user_name=by, action='repair_cash_safe_gold', entity_type='JournalEntry',
                        entity_id=posted.id, entity_number=entry_number,
                        details=json.dumps(result, ensure_ascii=False))
    return result
