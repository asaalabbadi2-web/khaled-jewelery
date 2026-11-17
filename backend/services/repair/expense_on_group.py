"""An expense booked on a group account, moved to its own account (the owner, 17 Nov 2026).

JE-2026-02177 (15 May 2026, a voucher «نقد», by admin) debited 1,000 riyals to
«5 المصروفات» -- the expenses' group itself. Gram profit read no group then,
so the riyals were never in it. The owner: they are the administrators' and
accountants' salaries -- «5470 رواتب المحاسبين والأداريين».

One entry, dated as the voucher, never an edit of a posted one: the group's
line reversed onto the account named, its own riyals. Refused, writing
nothing, when the entry is not posted, when it has not exactly one line on
the group, when that line carries grams, when the group has no account under
it, when the account named has accounts under it or is not on the group's
side (revenue or expense); a second run finds it done.
"""
from __future__ import annotations

import json

from models import Account, AuditLog, JournalEntry, db
from services.repair.entries import write_entry

MOVED = 'expense_on_group_moved'
GRAM_COLUMNS = ('18k', '21k', '22k', '24k', 'weight')


class NotAsFound(ValueError):
    pass


def _account(number: str) -> Account:
    found = Account.query.filter_by(account_number=number).one_or_none()
    if found is None:
        raise NotAsFound(f'{number}: no such account')
    return found


def move(*, by: str, now, entry_number: str, from_number: str, to_number: str) -> dict:
    """Write the move; the caller commits (the CLI rolls back a dry run)."""
    from services.gram_profit_accounts import gram_profit_standing
    entry = JournalEntry.query.filter_by(entry_number=entry_number).one_or_none()
    if entry is None or not entry.is_posted or entry.is_deleted:
        raise NotAsFound(f'{entry_number}: no posted entry')
    done = JournalEntry.query.filter(JournalEntry.reference_type == MOVED, JournalEntry.reference_id == entry.id,
                                     JournalEntry.is_deleted.isnot(True)).first()
    if done is not None:
        return {'already': True, 'entry': done.entry_number}
    group, to = _account(from_number), _account(to_number)
    if Account.query.filter_by(parent_id=group.id).count() == 0:
        raise NotAsFound(f'{from_number}: not a group -- nothing to move it to')
    if Account.query.filter_by(parent_id=to.id).count():
        raise NotAsFound(f'{to_number}: a group itself')
    standing = gram_profit_standing()
    side = standing[group.id].side
    if side is None or standing[to.id].side != side:
        raise NotAsFound(f'{to_number} is not on {from_number}\'s side ({side})')
    on_group = [l for l in entry.lines if not l.is_deleted and l.account_id == group.id]
    if len(on_group) != 1:
        raise NotAsFound(f'{entry_number}: {len(on_group)} lines on {from_number}, not one')
    [line] = on_group
    if any(float(getattr(line, f'{s}_{c}') or 0.0) for s in ('debit', 'credit') for c in GRAM_COLUMNS):
        raise NotAsFound(f'{entry_number}: its line on {from_number} carries grams')
    debit, credit = float(line.cash_debit or 0.0), float(line.cash_credit or 0.0)
    posted = write_entry(
        date=entry.date, reference_type=MOVED, reference_id=entry.id, reference_number=entry_number,
        description=f'تصحيح: {entry_number} على «{to.name}» لا على مجموعة «{group.name}» (المالك، 17 نوفمبر 2026)',
        lines=[{'account_id': group.id, 'description': f'من المجموعة «{group.name}»',
                'cash_debit': credit, 'cash_credit': debit},
               {'account_id': to.id, 'description': f'إلى «{to.name}»',
                'cash_debit': debit, 'cash_credit': credit}],
        by=by, now=now, entry_type='تصحيح')
    result = {'entry': posted.entry_number, 'date': entry.date.date().isoformat(), 'from': group.account_number,
              'to': to.account_number, 'cash_debit': debit, 'cash_credit': credit}
    AuditLog.log_action(user_name=by, action='repair_expense_on_group', entity_type='JournalEntry',
                        entity_id=posted.id, entity_number=entry_number,
                        details=json.dumps(result, ensure_ascii=False))
    return result
