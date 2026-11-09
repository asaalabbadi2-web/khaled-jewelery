"""An office's statement says the gold it holds for us (ADR-052; the owner, 9 Nov 2026).

The statement of an office's supplier reads the trade: its cash account and
its weight twin. Our gold the office holds is its deposit, an asset of ours
(services/office_deposits). This reads the deposit's posted lines into the
same statement -- a reader over two accounts, no second ledger:

- an entry with a row already (its trade line) carries its deposit
  movement on that row;
- an entry with none has a row of its own, the trade's running balances as
  the row before it left them;
- every row the custody's running balance, by karat and in the main karat.
"""
from __future__ import annotations

from sqlalchemy import func, or_

from models import JournalEntry, JournalEntryLine, db

KARATS = ('18k', '21k', '22k', '24k')


def _main(by_karat: dict) -> float:
    from pricing.karat_service import convert_to_main_karat
    return round(sum(convert_to_main_karat(float(by_karat.get(k) or 0.0), int(k[:-1])) for k in KARATS), 3)


def _delta(line) -> dict:
    return {k: round(float(getattr(line, f'debit_{k}') or 0.0) - float(getattr(line, f'credit_{k}') or 0.0), 6)
            for k in KARATS}


def add_custody(rows: list, supplier, *, order_key, iso, opening_cash: float, opening_gold: float,
                include_cancelled: bool):
    """The deposit's movements laid into *rows* (each carrying '_k', its order),
    custody-only rows inserted in order; returns the custody's summary -- or
    None for a supplier whose gold safe is no deposit (*rows* untouched)."""
    from services.cancelled_vouchers import without_cancelled_pairs
    from services.office_deposits import deposit_of

    deposit = deposit_of(supplier)
    if deposit is None or not deposit.account_id:
        return None
    lines = (JournalEntryLine.query.join(JournalEntry)
             .filter(JournalEntryLine.account_id == int(deposit.account_id),
                     JournalEntryLine.is_deleted.is_(False), JournalEntry.is_deleted.is_(False),
                     or_(func.coalesce(JournalEntry.is_posted, False).is_(True),
                         func.coalesce(JournalEntry.is_draft, False).is_(False)))
             .all())
    lines, _ = without_cancelled_pairs(lines, include=include_cancelled)

    opening = {k: 0.0 for k in KARATS}
    by_entry = {}
    for row in rows:
        by_entry.setdefault(row['journal_entry_id'], row)
    added = []
    for line in lines:
        je = line.journal_entry
        delta = _delta(line)
        if (je.entry_type or '') == 'افتتاحي':
            for k in KARATS:
                opening[k] += delta[k]
            continue
        row = by_entry.get(line.journal_entry_id)
        if row is None:
            row = {'id': line.id, 'date': iso(order_key(je, line.id)[0]),
                   # the entry says what moved the custody («سداد دفعة للمورد ...»); the
                   # deposit's own line says only «ذهب»
                   'description': je.description or line.description or '',
                   'journal_entry_id': je.id, 'entry_number': je.entry_number,
                   'reference_type': je.reference_type, 'reference_id': je.reference_id,
                   'reference_number': je.reference_number,
                   'cash_debit': 0.0, 'cash_credit': 0.0, 'gold_debit': 0.0, 'gold_credit': 0.0,
                   **{f'{side}_{k}': 0.0 for side in ('debit', 'credit') for k in KARATS},
                   'custody_only': True, '_k': order_key(je, line.id)}
            by_entry[je.id] = row
            added.append(row)
        moved = row.setdefault('custody_by_karat', {k: 0.0 for k in KARATS})
        for k in KARATS:
            moved[k] = round(moved[k] + delta[k], 6)

    rows.extend(added)
    rows.sort(key=lambda r: r['_k'])
    running = dict(opening)
    cash, gold = round(float(opening_cash or 0.0), 2), round(float(opening_gold or 0.0), 3)
    for row in rows:
        if row.get('custody_only'):
            row['running_cash_balance'], row['running_gold_balance'] = cash, gold
        else:
            cash, gold = row['running_cash_balance'], row['running_gold_balance']
        moved = row.setdefault('custody_by_karat', {k: 0.0 for k in KARATS})
        for k in KARATS:
            moved[k] = round(moved[k], 3)
            running[k] = round(running[k] + moved[k], 6)
        row['custody_main'] = _main(moved)
        row['running_custody_by_karat'] = {k: round(running[k], 3) for k in KARATS}
        row['running_custody_main'] = _main(running)
    return {'safe_box_id': deposit.id, 'name': deposit.name, 'account_id': deposit.account_id,
            'opening_by_karat': {k: round(opening[k], 3) for k in KARATS}, 'opening_main': _main(opening),
            'closing_by_karat': {k: round(running[k], 3) for k in KARATS}, 'closing_main': _main(running)}
