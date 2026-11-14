"""A cash or bank safe holds no gold -- refused at flush on every ORM path (the owner, 14 Nov 2026).

«راجع صندوق النقدية المالي عليه وزن قديم»: a customer's purchase of 17 Feb 2026
(JE-2026-00066) credited the 98.26 g of 24k it bought to «صندوق النقدية الرئيسي
وزني», the main cash box's weight twin -- «دفع وزني» -- instead of the
purchases' weight twin, and the cash box read -98.26 g for nine months: no
check compares a cash safe's grams (SAFEBOX_GOLD_DRIFT reads the gold safes).

The law: a line may not move the weight twin of a cash or bank safe's account
away from zero, karat by karat and in the main-karat weight. A line bringing
it back toward zero -- the correction of what an older writer left -- is
written. A safe's own account carries no grams already (a weight on a cash
account goes to its twin, 17 Oct 2026). The nightly check
CASH_SAFE_HOLDS_GOLD says what is left past this guard (raw SQL, old rows).

Registered by importing it (models.py). It reads through the flush's own
connection, so lines written earlier in the same transaction count.
"""
from sqlalchemy import event, inspect as sa_inspect, text

COLUMNS = ('18k', '21k', '22k', '24k', 'weight')
EPS = 0.0005


class CashSafeHoldsNoGold(ValueError):
    """A line putting grams on a cash or bank safe."""
    code = 'cash_safe_holds_no_gold'

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


def _grams(values: dict) -> dict:
    return {c: float(values.get(f'debit_{c}') or 0.0) - float(values.get(f'credit_{c}') or 0.0) for c in COLUMNS}


def _of(target) -> dict:
    return {f'{side}_{c}': getattr(target, f'{side}_{c}', None) for side in ('debit', 'credit') for c in COLUMNS}


def _cash_safe_of(connection, account_id):
    """The cash or bank safe whose account's weight twin *account_id* is, or None."""
    if account_id is None:
        return None
    return connection.execute(text(
        "SELECT s.name FROM safe_box s JOIN account a ON a.id = s.account_id "
        "WHERE a.memo_account_id = :id AND s.safe_type IN ('cash', 'bank') LIMIT 1"), {'id': account_id}).first()


def _balance(connection, account_id) -> dict:
    sums = ', '.join(f'COALESCE(SUM(COALESCE(l.debit_{c}, 0) - COALESCE(l.credit_{c}, 0)), 0)' for c in COLUMNS)
    row = connection.execute(text(
        f'SELECT {sums} FROM journal_entry_line l JOIN journal_entry e ON e.id = l.journal_entry_id '
        'WHERE l.account_id = :id AND COALESCE(l.is_deleted, FALSE) = FALSE '
        'AND COALESCE(e.is_deleted, FALSE) = FALSE'), {'id': account_id}).first()
    return {c: float(v or 0.0) for c, v in zip(COLUMNS, row)}


def _refuse_moving_away(connection, account_id, before: dict, after: dict):
    safe = _cash_safe_of(connection, account_id)
    if safe is None:
        return
    away = [c for c in COLUMNS if abs(after[c]) > abs(before[c]) + EPS]
    if away:
        raise CashSafeHoldsNoGold(
            f'صندوق «{safe[0]}» نقدي: لا يحمل ذهبًا، فلا يُكتب على حسابه الوزني جرام ({", ".join(away)}). '
            'الذهب على صندوق ذهب أو على حساب المشتريات أو الطرف الذي أعطاه.')


def register(JournalEntryLine):
    @event.listens_for(JournalEntryLine, 'before_insert')
    def _line_insert(mapper, connection, target):
        delta = _grams(_of(target))
        if getattr(target, 'is_deleted', False) or not any(abs(v) > EPS for v in delta.values()):
            return
        if _cash_safe_of(connection, target.account_id) is None:
            return
        before = _balance(connection, target.account_id)
        _refuse_moving_away(connection, target.account_id, before,
                            {c: before[c] + delta[c] for c in COLUMNS})

    @event.listens_for(JournalEntryLine, 'before_update')
    def _line_update(mapper, connection, target):
        state = sa_inspect(target)
        watched = ['account_id', 'is_deleted'] + [f'{s}_{c}' for s in ('debit', 'credit') for c in COLUMNS]
        if not any(state.attrs[k].history.has_changes() for k in watched if k in state.attrs):
            return
        cols = ', '.join(['account_id', 'COALESCE(is_deleted, FALSE)']
                         + [f'{s}_{c}' for s in ('debit', 'credit') for c in COLUMNS])
        row = connection.execute(text(f'SELECT {cols} FROM journal_entry_line WHERE id = :id'),
                                 {'id': target.id}).first()
        if row is None:
            return
        old_account, old_deleted = row[0], bool(row[1])
        old = dict(zip([f'{s}_{c}' for s in ('debit', 'credit') for c in COLUMNS], row[2:]))
        old_delta = {c: 0.0 for c in COLUMNS} if old_deleted else _grams(old)
        new_delta = {c: 0.0 for c in COLUMNS} if getattr(target, 'is_deleted', False) else _grams(_of(target))
        for account_id in {old_account, target.account_id}:
            if _cash_safe_of(connection, account_id) is None:
                continue
            before = _balance(connection, account_id)
            after = dict(before)
            for c in COLUMNS:
                if account_id == old_account:
                    after[c] -= old_delta[c]
                if account_id == target.account_id:
                    after[c] += new_delta[c]
            _refuse_moving_away(connection, account_id, before, after)


__all__ = ['CashSafeHoldsNoGold', 'register']
