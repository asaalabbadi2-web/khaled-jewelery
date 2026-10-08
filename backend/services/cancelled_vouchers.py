"""Cancelled vouchers and their reversals, hidden from a statement's view (the owner, 9 Oct 2026).

A cancelled voucher keeps its posted entry and gains a posted reversal
('voucher_reversal' -> the voucher, ADR-035): the books stay true, and the
statement shows two lines that cancel out. The owner: hide them by default in
what is shown and printed, and show them with a button -- the database keeps
every row; only the view changes.

The LAWS (tests/test_statements_hide_cancelled_vouchers.py):
  - a pair is hidden whole or not at all: the voucher's entry and every posted
    reversal of it;
  - only when the whole pair is in the statement (a period that cuts between
    the entry and its reversal shows both -- else the closing balance would
    lie);
  - only when the pair nets to zero on the lines shown, on every column (cash
    and each karat): hiding never moves a balance;
  - what is hidden is said: the response names how many and which vouchers.

POLICY: hidden by default (HIDE_BY_DEFAULT, the owner's choice); a request
with include_cancelled=1 shows them.
"""
from __future__ import annotations

from typing import Callable, Iterable, List, Tuple

from models import JournalEntry, Voucher, db

# Policy (the owner, 9 Oct 2026): the statement opens without them.
HIDE_BY_DEFAULT = True

_COLUMNS = ('cash', '18k', '21k', '22k', '24k')


def include_cancelled_requested(args) -> bool:
    """The statement's switch, from the request's query string."""
    raw = str(args.get('include_cancelled', '') or '').strip().lower()
    if raw in ('1', 'true', 'yes', 'on'):
        return True
    if raw in ('0', 'false', 'no', 'off'):
        return False
    return not HIDE_BY_DEFAULT


def _line_nets(line) -> Tuple[float, ...]:
    return (
        float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0),
        float(line.debit_18k or 0.0) - float(line.credit_18k or 0.0),
        float(line.debit_21k or 0.0) - float(line.credit_21k or 0.0),
        float(line.debit_22k or 0.0) - float(line.credit_22k or 0.0),
        float(line.debit_24k or 0.0) - float(line.credit_24k or 0.0),
    )


def cancelled_pairs(entry_ids: Iterable[int]) -> dict:
    """{voucher: [entry ids]} for each cancelled voucher whose entry is among
    *entry_ids*, with its posted reversals."""
    ids = {int(i) for i in entry_ids if i}
    if not ids:
        return {}
    vouchers = Voucher.query.filter(Voucher.status == 'cancelled', Voucher.journal_entry_id.in_(ids)).all()
    if not vouchers:
        return {}
    reversals = (db.session.query(JournalEntry.id, JournalEntry.reference_id)
                 .filter(JournalEntry.reference_type == 'voucher_reversal',
                         JournalEntry.reference_id.in_([v.id for v in vouchers]),
                         JournalEntry.is_posted.is_(True),
                         JournalEntry.is_deleted.is_(False))
                 .all())
    by_voucher: dict = {}
    for entry_id, voucher_id in reversals:
        by_voucher.setdefault(int(voucher_id), []).append(int(entry_id))
    return {v: [int(v.journal_entry_id)] + by_voucher[v.id] for v in vouchers if by_voucher.get(v.id)}


def without_cancelled_pairs(lines: List, *, include: bool,
                            entry_id_of: Callable = lambda line: line.journal_entry_id,
                            nets_of: Callable = _line_nets) -> Tuple[List, dict]:
    """(*lines* as the statement shows them, what was hidden).

    *lines* are a statement's journal lines (JournalEntryLine by default). With
    *include*, nothing is hidden and the count is still given, so the screen can
    say how many there are.
    """
    by_entry: dict = {}
    for line in lines:
        by_entry.setdefault(entry_id_of(line), []).append(line)

    hidden_entries: set = set()
    hidden_vouchers: List[dict] = []
    for voucher, entries in cancelled_pairs(by_entry.keys()).items():
        if not all(e in by_entry for e in entries):
            continue                                  # the period cuts the pair: both are shown
        totals = [0.0] * len(_COLUMNS)
        for e in entries:
            for line in by_entry[e]:
                for i, value in enumerate(nets_of(line)):
                    totals[i] += value
        if any(abs(t) > 0.005 for t in totals):
            continue                                  # not a whole cancellation on these lines
        hidden_entries.update(entries)
        hidden_vouchers.append({'voucher_id': voucher.id, 'voucher_number': voucher.voucher_number})

    summary = {
        'count': len(hidden_vouchers),
        'vouchers': sorted(v['voucher_number'] for v in hidden_vouchers),
        'hidden': not include and bool(hidden_vouchers),
    }
    if include or not hidden_entries:
        return lines, summary
    return [line for line in lines if entry_id_of(line) not in hidden_entries], summary
