"""A plan's corrections, written from the owner's figures -- one engine (ADR-088, ADR-089).

A repair the owner decides figure by figure (the 2026 opening, the 2026 VAT
returns) is a list of posted entries in a data file: policy as data, the
writer and its guards as code. This module is that writer, shared:

  - each account named by its role (`{"role": .., "operation": ..}`, ADR-046)
    or, where it has none, by number and name -- refused when the number
    names another account;
  - `expect_before` / `expect_period` / `expect_after`: the books as the plan
    found them and as it says they end, column by column, an account's whole
    balance or one period's movement -- refused, nothing kept, when they differ;
  - an account the plan makes (`made_accounts`): under its parent's role, with
    its weight twin, once;
  - a group of accounts (`groups`) that a line splits into by shares, to the
    thousandth, the remainder to the first named;
  - every entry a posted correction through services/repair/entries.write_entry
    (protected accounts refused but those the owner named), and a second run
    writes nothing.
"""
from __future__ import annotations

import datetime as dt
import json
from fractions import Fraction

from models import Account, JournalEntry, JournalEntryLine, db
from services.repair.entries import write_entry

COLUMNS = ('cash', '18k', '21k', '22k', '24k')
KARATS = ('18k', '21k', '22k', '24k')
EPS = 0.005
PLACES = 3


class PlanRefused(ValueError):
    """The books are not as the plan found them, or not as it says they end."""


def load(path: str) -> dict:
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


def norm(name) -> str:
    return ' '.join(str(name or '').split())


def resolve(specs: dict) -> dict:
    """{key: Account}: by role, or by number with its name confirming it."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    out, wrong = {}, []
    for key, spec in specs.items():
        if 'role' in spec:
            found = get_account_id_for_mapping(spec.get('operation') or DEFAULT_MAPPING_OPERATION_TYPE, spec['role'])
            if not found:
                wrong.append(f"{key}: الدور {spec['role']} غير مربوط")
                continue
            out[key] = db.session.get(Account, found)
            continue
        account = Account.query.filter_by(account_number=spec['number']).one_or_none()
        if account is None or norm(account.name) != norm(spec['name']):
            wrong.append(f"{key}: {spec['number']} «{spec['name']}» — "
                         f"{'لا حساب' if account is None else '«' + norm(account.name) + '»'}")
            continue
        out[key] = account
    if wrong:
        raise PlanRefused('حسابات لا تطابق الخطة: ' + '؛ '.join(wrong))
    return out


def _day(text):
    return dt.datetime.fromisoformat(text) if text else None


def balance(account_id: int, start: str | None = None, end: str | None = None) -> dict:
    """Debit minus credit, column by column, over the live lines of live entries
    -- all of them, or those dated from *start* to *end* (inclusive days)."""
    q = db.session.query(JournalEntryLine).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id) \
        .filter(JournalEntryLine.account_id == account_id,
                JournalEntryLine.is_deleted.isnot(True), JournalEntry.is_deleted.isnot(True))
    if start:
        q = q.filter(JournalEntry.date >= _day(start))
    if end:
        q = q.filter(JournalEntry.date < _day(end) + dt.timedelta(days=1))
    out = dict.fromkeys(COLUMNS, 0.0)
    for line in q:
        out['cash'] += float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0)
        for k in KARATS:
            out[k] += float(getattr(line, f'debit_{k}') or 0.0) - float(getattr(line, f'credit_{k}') or 0.0)
    return {k: round(v, 6) for k, v in out.items()}


def main_grams(bal: dict, main_karat: int) -> float:
    """A balance's grams in the main karat (debit positive)."""
    return sum(bal[k] * int(k[:-1]) / main_karat for k in KARATS)


def main_karat() -> int:
    from models import Settings
    row = Settings.query.first()
    karat = int(getattr(row, 'main_karat', 0) or 0) if row is not None else 0
    if not karat:
        raise PlanRefused('main_karat_not_set')     # the settings' own, never a fixed 21
    return karat


def differ(expected: dict, accounts: dict) -> list:
    """Each account's whole balance against the plan's."""
    out = []
    for key, columns in (expected or {}).items():
        bal = balance(accounts[key].id)
        for col, want in columns.items():
            if abs(bal[col] - float(want)) > EPS:
                out.append(f'{key} {col}: {bal[col]:,.3f} والخطة {float(want):,.3f}')
    return out


def period_differ(expected: list, accounts: dict) -> list:
    """Each period's movement on an account against the plan's."""
    out = []
    for item in expected or []:
        bal = balance(accounts[item['account']].id, item.get('from'), item.get('to'))
        for col in COLUMNS:
            if col in item and abs(bal[col] - float(item[col])) > EPS:
                out.append(f"{item['account']} {item.get('from')}…{item.get('to')} {col}: "
                           f"{bal[col]:,.3f} والخطة {float(item[col]):,.3f}")
    return out


def _side(columns: dict, side: str) -> dict:
    out = {}
    for col, amount in (columns or {}).items():
        if col not in COLUMNS:
            raise PlanRefused(f'عمود غير معروف: {col}')
        debit = side == 'dr'
        out[(f'cash_{"debit" if debit else "credit"}' if col == 'cash'
             else f'{"debit" if debit else "credit"}_{col}')] = float(amount)
    return out


def split(amount: float, shares: dict) -> dict:
    """*amount* by *shares*, to the gram's thousandth; the rounding's remainder
    to the first named."""
    keys = list(shares)
    parts = {k: round(float(Fraction(str(amount)) * Fraction(shares[k])), PLACES) for k in keys}
    parts[keys[0]] = round(parts[keys[0]] + round(float(amount) - sum(parts.values()), PLACES), PLACES)
    return parts


def lines(entry: dict, accounts: dict, groups: dict) -> list:
    out = []
    for spec in entry['lines']:
        columns = {**_side(spec.get('dr'), 'dr'), **_side(spec.get('cr'), 'cr')}
        if spec['account'] not in groups:
            out.append({'account_id': accounts[spec['account']].id, 'description': spec.get('note'), **columns})
            continue
        shares = groups[spec['account']]
        by_member = {k: {} for k in shares}
        for col, amount in columns.items():
            for k, part in split(amount, shares).items():
                by_member[k][col] = part
        for k, cols in by_member.items():
            out.append({'account_id': accounts[k].id, 'description': spec.get('note'), **cols})
    return out


def written(reference_type: str, key: str):
    return JournalEntry.query.filter(JournalEntry.reference_type == reference_type,
                                     JournalEntry.reference_number == key,
                                     JournalEntry.is_deleted.isnot(True)).first()


def make_account(spec: dict, *, by: str) -> tuple:
    """(the made account, made now?) -- under its parent role's account, with its weight twin."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    from account_number_generator import get_next_account_number
    from employee_account_helpers import ensure_memo_for_account

    parent = db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, spec['parent_role']))
    found = Account.query.filter_by(parent_id=parent.id).filter(Account.name == spec['name']).one_or_none()
    if found is not None:
        return found, False
    account = Account(account_number=str(get_next_account_number(str(parent.account_number))), name=spec['name'],
                      type=spec.get('type', 'Asset'), transaction_type='cash', tracks_weight=False, parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    ensure_memo_for_account(account)
    db.session.flush()
    return account, True


def _made_specs(figures: dict) -> list:
    if 'made_accounts' in figures:
        return figures['made_accounts']
    return [figures['made_account']] if 'made_account' in figures else []


def write_plan(figures: dict, *, by: str, now: dt.datetime, check=None) -> dict:
    """Write the plan's entries; refuse, keeping nothing, when the books differ
    from it before (the caller rolls back on the after-check). Returns the
    accounts, the entries written and the accounts made -- or `already`."""
    ref = figures['reference_type']
    accounts = resolve(figures['accounts'])
    keys = [e['key'] for e in figures['entries']]
    done = [k for k in keys if written(ref, k) is not None]
    if done and len(done) == len(keys):
        for spec in _made_specs(figures):
            accounts[spec['key']], _ = make_account(spec, by=by)
        return {'already': True, 'accounts': accounts, 'entries': done}
    if done:
        raise PlanRefused(f'كُتب بعض القيود دون بعض ({", ".join(done)}): لا يُكمَل تلقائيًّا')

    before = differ(figures.get('expect_before'), accounts) + period_differ(figures.get('expect_period'), accounts)
    if check is not None:                 # the plan's own reading of the books (its caller's)
        before += check(accounts)
    if before:
        raise PlanRefused('الدفاتر غير ما وجدته الخطة: ' + '؛ '.join(before))

    made = {}
    for spec in _made_specs(figures):
        accounts[spec['key']], made[spec['key']] = make_account(spec, by=by)
    allow = {accounts[k].id for k in figures.get('protected_allowed', [])}
    groups = figures.get('groups', {})
    out = []
    for i, entry in enumerate(figures['entries'], start=1):
        posted = write_entry(date=dt.datetime.fromisoformat(entry['date']), description=entry['description'],
                             reference_type=ref, reference_id=i, reference_number=entry['key'],
                             lines=lines(entry, accounts, groups), by=by, now=now,
                             prefix='COR', entry_type=entry['type'], allow_protected=allow)
        out.append({'key': entry['key'], 'entry': posted.entry_number, 'date': entry['date'], 'id': posted.id})
    return {'already': False, 'accounts': accounts, 'entries': out,
            'made': {k: {'number': accounts[k].account_number, 'made': v} for k, v in made.items()}}
