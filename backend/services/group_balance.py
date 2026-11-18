"""A group account's own balance, and its move to an account under it (the owner, 18 Nov 2026).

«تحذير بحيث يمكن اضافة حساب فرعي ونقل الرصيد اليه»: an account posted to
and then given an account under it -- «5440» used on 28 Apr 2026, «5440000»
made under it on 30 Apr -- holds a balance of its own on a group, which no
report names and the guard (parent_account_guard) lets only go back to zero.
Adding an account under one with a balance is warned of, with its move.

The move: one entry per entry the group's balance came from, dated as it --
a month's report keeps its month -- the group's net there moved onto the
account named; never an edit of a posted one. An entry and its reversal (a
voucher cancelled) net to nothing and are not moved. What is left must all
be on the balance's side, column by column, so each move brings the group
toward zero and none crosses it; otherwise it is refused, writing nothing,
as is an account named that is not under the group or has accounts under it.
A second move finds the entries moved.
"""
from __future__ import annotations

import json

from models import Account, AuditLog, JournalEntry, JournalEntryLine, db

MOVED = 'group_balance_moved'
PAIRS = (('cash_debit', 'cash_credit'),) + tuple(
    (f'debit_{k}', f'credit_{k}') for k in ('18k', '21k', '22k', '24k', 'weight'))
COLUMNS = tuple(d.replace('debit_', '').replace('_debit', '') for d, _ in PAIRS)   # cash, 18k, ... weight
EPS = {'cash': 0.005, **{c: 0.0005 for c in COLUMNS[1:]}}
# An entry that reverses another: (its reference type, how it names what it reverses).
REVERSALS = {'voucher_reversal': ('voucher', 'reference_id'), 'journal_entry_reversal': (None, 'id')}


class GroupBalanceRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _has_children(account_id: int) -> bool:
    return db.session.query(Account.id).filter(Account.parent_id == account_id).first() is not None


def _under(account: Account, group: Account) -> bool:
    seen, parent_id = set(), account.parent_id
    while parent_id is not None and parent_id not in seen:
        if parent_id == group.id:
            return True
        seen.add(parent_id)
        parent_id = db.session.query(Account.parent_id).filter(Account.id == parent_id).scalar()
    return False


def _nets(group: Account) -> dict:
    """{entry: {column: debit less credit}} of the group's own lines, entry by entry."""
    rows = (db.session.query(JournalEntry, JournalEntryLine)
            .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
            .filter(JournalEntryLine.account_id == group.id, JournalEntryLine.is_deleted.isnot(True),
                    JournalEntry.is_deleted.isnot(True), JournalEntry.is_posted.is_(True))
            .order_by(JournalEntry.date, JournalEntry.id).all())
    out: dict = {}
    for entry, line in rows:
        net = out.setdefault(entry, {c: 0.0 for c in COLUMNS})
        for column, (debit, credit) in zip(COLUMNS, PAIRS):
            net[column] += float(getattr(line, debit) or 0.0) - float(getattr(line, credit) or 0.0)
    return {e: n for e, n in out.items() if any(abs(n[c]) > EPS[c] for c in COLUMNS)}


def own_balance(group: Account) -> dict:
    """The group's own balance -- riyals and grams -- and the entries it is in."""
    nets = _nets(group)
    total = {c: round(sum(n[c] for n in nets.values()), 3 if c != 'cash' else 2) for c in COLUMNS}
    return {'cash': total['cash'], 'grams': {c: total[c] for c in COLUMNS[1:]},
            'entries': len(nets), 'any': any(abs(total[c]) > EPS[c] for c in COLUMNS)}


def _to_move(group: Account) -> list:
    """The entries whose net on the group moves -- an entry and its reversal
    netting to nothing left out, and those already moved."""
    nets = {e: n for e, n in _nets(group).items() if e.reference_type != MOVED}
    moved = {r for (r,) in db.session.query(JournalEntry.reference_id).filter(
        JournalEntry.reference_type == MOVED, JournalEntry.is_deleted.isnot(True),
        JournalEntry.reference_number == group.account_number)}
    nets = {e: n for e, n in nets.items() if e.id not in moved}
    gone = set()
    for entry, net in nets.items():
        kind = REVERSALS.get(entry.reference_type or '')
        if kind is None:
            continue
        original_type, by = kind
        original = next((o for o in nets if o is not entry and o not in gone and (
            (by == 'id' and o.id == entry.reference_id) or
            (by == 'reference_id' and o.reference_type == original_type and o.reference_id == entry.reference_id))),
            None)
        if original is not None and all(abs(net[c] + nets[original][c]) <= EPS[c] for c in COLUMNS):
            gone |= {entry, original}
    return [(e, n) for e, n in nets.items() if e not in gone]


def move(group_id: int, to_id: int, *, by: str, now) -> dict:
    """Move the group's own balance onto *to_id*; the caller commits."""
    from services.repair.entries import write_entry
    group, to = db.session.get(Account, int(group_id)), db.session.get(Account, int(to_id))
    if group is None or to is None:
        raise GroupBalanceRefused('account_not_found', 'الحساب غير موجود')
    if not _has_children(group.id):
        raise GroupBalanceRefused('not_a_group', f'«{group.account_number}» ليس تحته حسابات: رصيده رصيده')
    if not _under(to, group):
        raise GroupBalanceRefused('not_under_group', f'«{to.account_number}» ليس تحت «{group.account_number}»')
    if _has_children(to.id):
        raise GroupBalanceRefused('target_is_group', f'«{to.account_number}» تحته حسابات: يُنقل إلى حساب تفصيلي')
    entries = _to_move(group)
    if not entries:
        return {'moved': 0, 'entries': [], 'cash': 0.0, 'grams': {c: 0.0 for c in COLUMNS[1:]}}
    total = {c: sum(n[c] for _, n in entries) for c in COLUMNS}
    against = sorted({e.entry_number for e, n in entries for c in COLUMNS
                      if abs(n[c]) > EPS[c] and abs(total[c]) > EPS[c] and n[c] * total[c] < 0})
    if against:
        raise GroupBalanceRefused('group_balance_mixed',
                                  f'في رصيد «{group.account_number}» قيود بعكس اتجاهه لا يقابلها عكسها '
                                  f'({", ".join(against[:5])}): يُنقل كل قيد منها بأداة التصحيح، لا مرة واحدة')
    written = []
    for entry, net in entries:
        group_line = {'account_id': group.id, 'description': f'من «{group.account_number} {group.name}»'}
        to_line = {'account_id': to.id, 'description': f'إلى «{to.account_number} {to.name}»'}
        for column, (debit, credit) in zip(COLUMNS, PAIRS):
            value = round(net[column], 2 if column == 'cash' else 3)
            if abs(value) <= EPS[column]:
                continue
            group_line[credit if value > 0 else debit] = abs(value)
            to_line[debit if value > 0 else credit] = abs(value)
        posted = write_entry(
            date=entry.date, reference_type=MOVED, reference_id=entry.id, reference_number=group.account_number,
            description=f'نقل: {entry.entry_number} من الحساب الرئيسي «{group.name}» إلى «{to.name}»',
            lines=[group_line, to_line], by=by, now=now, entry_type='تصحيح')
        written.append(posted.entry_number)
    result = {'moved': len(written), 'entries': written, 'from': group.account_number, 'to': to.account_number,
              'cash': round(total['cash'], 2), 'grams': {c: round(total[c], 3) for c in COLUMNS[1:]}}
    AuditLog.log_action(user_name=by, action='move_group_balance', entity_type='Account', entity_id=group.id,
                        entity_number=group.account_number, details=json.dumps(result, ensure_ascii=False))
    return result
