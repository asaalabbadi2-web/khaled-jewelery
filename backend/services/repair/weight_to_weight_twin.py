"""Grams on a cash account move to its weight twin, entry by entry at its date (ADR-051).

The mirror of stage4's cash_moved_to_financial_twin. A cash account carries
no grams; the distribution sends them to the twin, but stood aside when the
twin was in the same entry -- so the calibration JE-2026-06478 (12 Oct,
«معايرة ذهب عيار ١٨ الى عيار ٢١») left 1,677.171 g of 21k on the Arab pound's
cash account 2100001, and its weight account 72100001 -- read as the safe
«حسابنا بشركة الجنيه العربي» -- showed -1,677 g the owner does not hold. The
only such line in the 2026 books (17 Oct copy).

The party's balance (both accounts read together) is unchanged; the weight
account and its safe's statement take the grams. Caller commits.
"""
from __future__ import annotations

import json

from models import Account, AuditLog, JournalEntry, JournalEntryLine, db
from services.repair.entries import write_entry

RECLASSIFICATION = 'stage4_reclassification'
KARATS = (18, 21, 22, 24)


def _weight_twin(account):
    twin = db.session.get(Account, account.memo_account_id) if account.memo_account_id else None
    return twin if twin is not None and twin.tracks_weight else None


def entries_with_grams_on_cash_accounts() -> list:
    """(entry, cash account, its weight twin, {karat: net grams}) for each posted
    entry that left grams on a cash account with a weight twin."""
    from accounting.balances import counted_line_filters
    rows = (db.session.query(JournalEntryLine)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .join(Account, Account.id == JournalEntryLine.account_id)
            .filter(Account.tracks_weight.isnot(True), *counted_line_filters())
            # A correction's own undo line is on the cash account by design: never moved again.
            .filter(db.func.coalesce(JournalEntry.reference_type, '') != RECLASSIFICATION)
            .order_by(JournalEntry.date, JournalEntry.id).all())
    found = {}
    for line in rows:
        net = {k: float(getattr(line, f'debit_{k}k') or 0) - float(getattr(line, f'credit_{k}k') or 0) for k in KARATS}
        if not any(abs(v) > 1e-9 for v in net.values()):
            continue
        key = (line.journal_entry_id, line.account_id)
        acc = found.setdefault(key, {k: 0.0 for k in KARATS})
        for k, v in net.items():
            acc[k] += v
    out = []
    for (entry_id, account_id), net in found.items():
        account = db.session.get(Account, account_id)
        out.append((db.session.get(JournalEntry, entry_id), account, _weight_twin(account),
                    {k: round(v, 3) for k, v in net.items() if abs(v) > 1e-9}))
    return out


def move_grams_to_weight_twin(*, by, now, dry_run=True) -> list:
    out = []
    for entry, account, twin, net in entries_with_grams_on_cash_accounts():
        plan = {'entry': entry.entry_number, 'date': entry.date, 'account': account.account_number,
                'grams': {f'{k}k': v for k, v in net.items()}}
        if twin is None:
            plan['refused'] = 'no weight twin: the owner decides where these grams belong'
            out.append(plan)
            continue
        if JournalEntry.query.filter_by(reference_type=RECLASSIFICATION, reference_id=entry.id,
                                        is_posted=True, is_deleted=False).first() is not None:
            out.append({**plan, 'done': True})
            continue
        undo = {'account_id': account.id, 'description': f'نقل الوزن إلى الحساب الوزني {twin.account_number}'}
        put = {'account_id': twin.id, 'description': f'وزن قُيّد على الحساب المالي {account.account_number}'}
        for k, v in net.items():
            undo[f'debit_{k}k'], undo[f'credit_{k}k'] = max(-v, 0.0), max(v, 0.0)
            put[f'debit_{k}k'], put[f'credit_{k}k'] = max(v, 0.0), max(-v, 0.0)
        plan['twin'] = twin.account_number
        if not dry_run:
            correction = write_entry(date=entry.date, description=f'نقل وزن {entry.entry_number} من الحساب المالي إلى الوزني',
                                     reference_type=RECLASSIFICATION, reference_id=entry.id,
                                     reference_number=entry.entry_number, lines=[undo, put], by=by, now=now)
            plan['correction'] = correction.entry_number
            AuditLog.log_action(user_name=by, action='repair_move_grams_to_weight_twin', entity_type='JournalEntry',
                                entity_id=entry.id, entity_number=entry.entry_number,
                                details=json.dumps(plan, ensure_ascii=False, default=str))
        out.append(plan)
    return out
