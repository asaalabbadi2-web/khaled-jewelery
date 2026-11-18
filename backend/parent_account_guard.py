"""An account with accounts under it takes no posting -- refused at flush on every ORM path (the owner, 18 Nov 2026).

«5440 هذا الحساب مادام له فروع لماذا يظهر في قائمة حسابات السند»: nine vouchers
of 28 Apr - 18 Sep 2026 (28,222.21) debited «5440 رسوم التراخيص ومخالفات»
itself -- the voucher screen judged a detail account by its number's length
until ACCT-LEAF-1 (15 Oct 2026), and offered 48 groups. The screens hide a
group since; the server took one from any path, and only the nightly check
GROUP_ACCOUNT_POSTED said so after.

The law: a line may not move the own balance of an account with accounts
under it away from zero -- riyals, or any karat's grams. A line bringing it
back toward zero is written: a voucher on it cancelled, the owner's move of
its balance to an account under it (services/group_balance), a year's
closing. Every daily writer posts to the accounts under the groups since the
chart was reorganised (the last invoice line on a group 13 Jun 2026, the last
office reservation 1 Oct; measured on the 18 Nov backup).

Registered by importing it (models.py). It reads through the flush's own
connection, so lines written earlier in the same transaction count.
"""
from sqlalchemy import event, inspect as sa_inspect, text

GRAMS = ('18k', '21k', '22k', '24k', 'weight')
COLUMNS = ('cash', *GRAMS)
EPS = {'cash': 0.005, **{c: 0.0005 for c in GRAMS}}


REQUEST_KEY = 'yasargold.group_account_posted'


class GroupAccountPosted(ValueError):
    """A line moving a group account's own balance away from zero."""
    code = 'group_account_posted'

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


def _side(column: str, side: str) -> str:
    return f'cash_{side}' if column == 'cash' else f'{side}_{column}'


def _delta(values: dict) -> dict:
    return {c: float(values.get(_side(c, 'debit')) or 0.0) - float(values.get(_side(c, 'credit')) or 0.0)
            for c in COLUMNS}


def _of(target) -> dict:
    return {_side(c, s): getattr(target, _side(c, s), None) for s in ('debit', 'credit') for c in COLUMNS}


def _group(connection, account_id):
    """(number, name) of *account_id* when accounts are under it, else None."""
    if account_id is None:
        return None
    return connection.execute(text(
        'SELECT a.account_number, a.name FROM account a '
        'WHERE a.id = :id AND EXISTS (SELECT 1 FROM account c WHERE c.parent_id = a.id)'),
        {'id': account_id}).first()


def _balance(connection, account_id) -> dict:
    sums = ', '.join(f'COALESCE(SUM(COALESCE(l.{_side(c, "debit")}, 0) - COALESCE(l.{_side(c, "credit")}, 0)), 0)'
                     for c in COLUMNS)
    row = connection.execute(text(
        f'SELECT {sums} FROM journal_entry_line l JOIN journal_entry e ON e.id = l.journal_entry_id '
        'WHERE l.account_id = :id AND COALESCE(l.is_deleted, FALSE) = FALSE '
        'AND COALESCE(e.is_deleted, FALSE) = FALSE'), {'id': account_id}).first()
    return {c: float(v or 0.0) for c, v in zip(COLUMNS, row)}


def _mark_the_request(refused):
    """Kept on the request, so its answer says it whatever the route made of
    it -- a refusal raised in an autoflush is often swallowed, and the request
    goes on to a session already rolled back (as the period lock's)."""
    from flask import has_request_context, request
    if has_request_context():
        request.environ.setdefault(REQUEST_KEY, refused)


def answered_readably(response, logger=None):
    """A request refused by the guard answers 400 group_account_posted with the
    refusal's words, in place of the error the route made of it; one that
    answered success although a line was refused is logged as an error."""
    from flask import has_request_context, jsonify, request
    if not has_request_context():
        return response
    refused = request.environ.get(REQUEST_KEY)
    if refused is None:
        return response
    if response.status_code >= 400:
        readable = jsonify({'error': refused.code, 'message': refused.message})
        readable.status_code = 400
        return readable
    if logger is not None:
        logger.error('group_account_posted swallowed: %s %s answered %s although a line was refused: %s',
                     request.method, request.path, response.status_code, refused.message)
    return response


def _refuse_moving_away(group, before: dict, after: dict):
    away = [c for c in COLUMNS if abs(after[c]) > abs(before[c]) + EPS[c]]
    if away:
        number, name = group
        refused = GroupAccountPosted(
            f'«{number} {name}» حساب رئيسي تحته حسابات: يُقيَّد على أحد فروعه، لا عليه '
            f'({", ".join("ريال" if c == "cash" else c for c in away)}).')
        _mark_the_request(refused)
        raise refused


def register(JournalEntryLine):
    @event.listens_for(JournalEntryLine, 'before_insert')
    def _line_insert(mapper, connection, target):
        delta = _delta(_of(target))
        if getattr(target, 'is_deleted', False) or not any(abs(delta[c]) > EPS[c] for c in COLUMNS):
            return
        group = _group(connection, target.account_id)
        if group is None:
            return
        before = _balance(connection, target.account_id)
        _refuse_moving_away(group, before, {c: before[c] + delta[c] for c in COLUMNS})

    @event.listens_for(JournalEntryLine, 'before_update')
    def _line_update(mapper, connection, target):
        state = sa_inspect(target)
        watched = ['account_id', 'is_deleted'] + [_side(c, s) for s in ('debit', 'credit') for c in COLUMNS]
        if not any(state.attrs[k].history.has_changes() for k in watched if k in state.attrs):
            return
        names = [_side(c, s) for s in ('debit', 'credit') for c in COLUMNS]
        row = connection.execute(text(
            f'SELECT account_id, COALESCE(is_deleted, FALSE), {", ".join(names)} FROM journal_entry_line WHERE id = :id'),
            {'id': target.id}).first()
        if row is None:
            return
        old_account, old_deleted = row[0], bool(row[1])
        old_delta = {c: 0.0 for c in COLUMNS} if old_deleted else _delta(dict(zip(names, row[2:])))
        new_delta = {c: 0.0 for c in COLUMNS} if getattr(target, 'is_deleted', False) else _delta(_of(target))
        for account_id in {old_account, target.account_id}:
            group = _group(connection, account_id)
            if group is None:
                continue
            before = _balance(connection, account_id)
            after = dict(before)
            for c in COLUMNS:
                if account_id == old_account:
                    after[c] -= old_delta[c]
                if account_id == target.account_id:
                    after[c] += new_delta[c]
            _refuse_moving_away(group, before, after)


__all__ = ['GroupAccountPosted', 'answered_readably', 'register']
