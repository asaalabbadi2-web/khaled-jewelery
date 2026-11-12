"""2026 opens on what the shop held, each debt on its owner (ADR-088, the owner 11-12 Nov 2026).

The 2026 opening was booked net: JE-2026-00001 took the count's gold less the
partners' withdrawal and the items written off, and later entries set each
debt against the display stock -- a cash debt turned into grams at 440 through
«حساب وسيط تسوية الذهب». The partners' withdrawal was kept off the books; part
of what they took sat in «دفتر التعامل الوزني», part was not recorded at all;
and payments made in December and January were never entered, so the April
reconciliations carried them into «عجز / فائض الخزائن».

The owner: «الأصل أن نسجّل الذهب الموجود كما هو، والسحبيات وغيرها تُسجَّل
لكي تتطابق أوزان العيارات». So each entry of the plan
(docs/plans/opening-2026-reorganization.md) is written here as a posted
correction -- no posted row edited -- from the owner's figures in
opening_2026.json: policy as data, each account named there by number and
name, and refused when the number names another account.

Refused, nothing written, when the books are not as the plan found them
(expect_before, the opening entry's stock lines): the figures were measured
on the 12 Nov copy, and production must agree before they are applied. And
refused after writing -- the caller rolls back -- when the result is not the
plan's (expect_after, each partner, the opening). A second run finds every
entry written and writes nothing.

«حساب وسيط تسوية الذهب» (1720/71720) is protected from every repair since
3 Oct 2026; the owner allowed this repair alone to zero it (12 Nov 2026).
Nothing here touches a tax account (the owner, 12 Nov 2026): the 21.28 g of
Lazurde's VAT stays in «دفتر التعامل الوزني» until the VAT work.
"""
from __future__ import annotations

import datetime as dt
import json
import os
from fractions import Fraction

from models import Account, AuditLog, JournalEntry, JournalEntryLine, db
from services.repair.entries import write_entry

FIGURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'opening_2026.json')
COLUMNS = ('cash', '18k', '21k', '22k', '24k')
KARATS = ('18k', '21k', '22k', '24k')
EPS = 0.005
PLACES = 3


class OpeningRefused(ValueError):
    """The books are not as the plan found them, or not as it says they end."""


def load(path: str = FIGURES) -> dict:
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


def _norm(name) -> str:
    return ' '.join(str(name or '').split())


def _resolve(figures: dict) -> dict:
    """{key: Account} -- each by its number, its name confirming it."""
    out, wrong = {}, []
    for key, spec in figures['accounts'].items():
        account = Account.query.filter_by(account_number=spec['number']).one_or_none()
        if account is None or _norm(account.name) != _norm(spec['name']):
            wrong.append(f"{key}: {spec['number']} «{spec['name']}» — "
                         f"{'لا حساب' if account is None else '«' + _norm(account.name) + '»'}")
            continue
        out[key] = account
    if wrong:
        raise OpeningRefused('حسابات لا تطابق الخطة: ' + '؛ '.join(wrong))
    return out


def balance(account_id: int) -> dict:
    """Debit minus credit, column by column, over the live lines of live entries."""
    q = db.session.query(JournalEntryLine).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id) \
        .filter(JournalEntryLine.account_id == account_id,
                JournalEntryLine.is_deleted.isnot(True), JournalEntry.is_deleted.isnot(True))
    out = dict.fromkeys(COLUMNS, 0.0)
    for line in q:
        out['cash'] += float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0)
        for k in KARATS:
            out[k] += float(getattr(line, f'debit_{k}') or 0.0) - float(getattr(line, f'credit_{k}') or 0.0)
    return {k: round(v, 6) for k, v in out.items()}


def _main(bal: dict, main_karat: int) -> float:
    """A balance's grams in the main karat (debit positive)."""
    return sum(bal[k] * int(k[:-1]) / main_karat for k in KARATS)


def _main_karat() -> int:
    from models import Settings
    row = Settings.query.first()
    karat = int(getattr(row, 'main_karat', 0) or 0) if row is not None else 0
    if not karat:
        raise OpeningRefused('main_karat_not_set')     # the settings' own, never a fixed 21
    return karat


def _differ(expected: dict, accounts: dict) -> list:
    out = []
    for key, columns in expected.items():
        bal = balance(accounts[key].id)
        for col, want in columns.items():
            if abs(bal[col] - float(want)) > EPS:
                out.append(f'{key} {col}: {bal[col]:,.3f} والخطة {float(want):,.3f}')
    return out


def _opening_lines_differ(figures: dict, accounts: dict) -> list:
    entry = JournalEntry.query.filter_by(entry_number=figures['opening_entry']).one_or_none()
    if entry is None or entry.is_deleted:
        return [f"قيد الافتتاح {figures['opening_entry']} غير موجود"]
    out = []
    for key, columns in figures['expect_opening_lines'].items():
        lines = [l for l in entry.lines if l.account_id == accounts[key].id and not l.is_deleted]
        for col, want in columns.items():
            got = sum(float(getattr(l, f'debit_{col}') or 0.0) - float(getattr(l, f'credit_{col}') or 0.0) for l in lines)
            if abs(got - float(want)) > EPS:
                out.append(f'{figures["opening_entry"]} {key} {col}: {got:,.3f} والخطة {float(want):,.3f}')
    return out


def _side(columns: dict, side: str) -> dict:
    out = {}
    for col, amount in (columns or {}).items():
        if col not in COLUMNS:
            raise OpeningRefused(f'عمود غير معروف: {col}')
        out[f'cash_{"debit" if side == "dr" else "credit"}' if col == 'cash'
            else f'{"debit" if side == "dr" else "credit"}_{col}'] = float(amount)
    return out


def _split(amount: float, shares: dict) -> dict:
    """*amount* by the Riyadh partners' shares, to the gram's thousandth; the
    rounding's remainder to the first named."""
    keys = list(shares)
    parts = {k: round(float(Fraction(str(amount)) * Fraction(shares[k])), PLACES) for k in keys}
    parts[keys[0]] = round(parts[keys[0]] + round(float(amount) - sum(parts.values()), PLACES), PLACES)
    return parts


def _lines(entry: dict, accounts: dict, shares: dict) -> list:
    out = []
    for spec in entry['lines']:
        columns = {**_side(spec.get('dr'), 'dr'), **_side(spec.get('cr'), 'cr')}
        if spec['account'] != 'riyadh':
            out.append({'account_id': accounts[spec['account']].id, 'description': spec.get('note'), **columns})
            continue
        by_partner = {k: {} for k in shares}
        for col, amount in columns.items():
            for k, part in _split(amount, shares).items():
                by_partner[k][col] = part
        for k, cols in by_partner.items():
            out.append({'account_id': accounts[k].id, 'description': spec.get('note'), **cols})
    return out


def _written(reference_type: str, key: str):
    return JournalEntry.query.filter(JournalEntry.reference_type == reference_type,
                                     JournalEntry.reference_number == key,
                                     JournalEntry.is_deleted.isnot(True)).first()


def _earrings_account(figures: dict, *, by: str) -> tuple:
    """(the made account, made now?) -- under its parent role's account, with its weight twin."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    from account_number_generator import get_next_account_number
    from employee_account_helpers import ensure_memo_for_account

    spec = figures['made_account']
    parent = db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, spec['parent_role']))
    found = Account.query.filter_by(parent_id=parent.id).filter(Account.name == spec['name']).one_or_none()
    if found is not None:
        return found, False
    account = Account(account_number=str(get_next_account_number(str(parent.account_number))), name=spec['name'],
                      type='Asset', transaction_type='cash', tracks_weight=False, parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    ensure_memo_for_account(account)
    db.session.flush()
    return account, True


def report(figures: dict, accounts: dict) -> dict:
    """What the plan reads after: its accounts, each partner, the opening."""
    karat = _main_karat()
    watched = {k: balance(accounts[k].id) for k in figures['expect_after']}
    partners = {k: round(_main(balance(accounts[k].id), karat), 2) for k in figures['expect_partners_main']}
    w = _main(balance(accounts['capital_w'].id), karat) + _main(balance(accounts['opening_adjust_w'].id), karat)
    opening = round(-(w + balance(accounts['capital_c'].id)['cash'] / float(figures['count_price'])), 2)
    return {'accounts': watched, 'partners_main': partners, 'opening_main': opening}


def reorganize(*, by: str, now: dt.datetime, figures: dict | None = None) -> dict:
    """Write the plan's entries; refuse, writing nothing, when the books differ
    from it before or after. The caller commits (the CLI rolls back a dry run)."""
    figures = figures or load()
    ref = figures['reference_type']
    accounts = _resolve(figures)
    keys = [e['key'] for e in figures['entries']]
    done = [k for k in keys if _written(ref, k) is not None]
    made_key = figures['made_account']['key']
    if done and len(done) == len(keys):
        accounts[made_key], _ = _earrings_account(figures, by=by)
        return {'already': True, 'entries': done, 'after': report(figures, accounts)}
    if done:
        raise OpeningRefused(f'كُتب بعض القيود دون بعض ({", ".join(done)}): لا يُكمَل تلقائيًّا')

    before = _differ(figures['expect_before'], accounts) + _opening_lines_differ(figures, accounts)
    if before:
        raise OpeningRefused('الدفاتر غير ما وجدته الخطة: ' + '؛ '.join(before))

    accounts[made_key], made = _earrings_account(figures, by=by)
    allow = {accounts[k].id for k in figures['protected_allowed']}
    written, first = [], None
    for i, entry in enumerate(figures['entries'], start=1):
        posted = write_entry(date=dt.datetime.fromisoformat(entry['date']), description=entry['description'],
                             reference_type=ref, reference_id=i, reference_number=entry['key'],
                             lines=_lines(entry, accounts, figures['riyadh_shares']), by=by, now=now,
                             prefix='COR', entry_type=entry['type'], allow_protected=allow)
        written.append({'key': entry['key'], 'entry': posted.entry_number, 'date': entry['date']})
        first = first or posted

    after = report(figures, accounts)
    wrong = _differ(figures['expect_after'], accounts)
    wrong += [f'{k}: {after["partners_main"][k]:,.2f} والخطة {float(v):,.2f}'
              for k, v in figures['expect_partners_main'].items() if abs(after['partners_main'][k] - float(v)) > 0.02]
    if abs(after['opening_main'] - float(figures['expect_opening_main'])) > 0.02:
        wrong.append(f'الافتتاح {after["opening_main"]:,.2f} والخطة {float(figures["expect_opening_main"]):,.2f}')
    if wrong:
        raise OpeningRefused('النتيجة غير ما تقوله الخطة: ' + '؛ '.join(wrong))

    result = {'entries': written, 'made_account': {'number': accounts[made_key].account_number, 'made': made},
              'after': after}
    AuditLog.log_action(user_name=by, action='repair_opening_2026', entity_type='JournalEntry', entity_id=first.id,
                        entity_number=ref, details=json.dumps(result, ensure_ascii=False, default=str))
    return result
