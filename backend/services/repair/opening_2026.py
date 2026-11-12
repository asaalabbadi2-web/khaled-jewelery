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
(docs/plans/opening-2026-reorganization.md) is written as a posted
correction -- no posted row edited -- from the owner's figures in
opening_2026.json, by the shared writer (services/repair/planned_entries).

Refused, nothing written, when the books are not as the plan found them
(expect_before, the opening entry's stock lines): the figures were measured
on the 12 Nov copy, and production must agree before they are applied. And
refused after writing -- the caller rolls back -- when the result is not the
plan's (expect_after, each partner, the opening). A second run finds every
entry written and writes nothing.

«حساب وسيط تسوية الذهب» (1720/71720) is protected from every repair since
3 Oct 2026; the owner allowed this repair alone to zero it (12 Nov 2026).
Nothing here touches a tax account (the owner, 12 Nov 2026): the 21.28 g of
Lazurde's VAT stays in «دفتر التعامل الوزني» until the VAT work (ADR-089).
"""
from __future__ import annotations

import datetime as dt
import json
import os

from models import AuditLog, JournalEntry
from services.repair.planned_entries import (  # noqa: F401  (the names the tests and tools import)
    COLUMNS, EPS, KARATS, PlanRefused, balance, differ, load as _load, main_grams, main_karat, split, write_plan,
)

FIGURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'opening_2026.json')

OpeningRefused = PlanRefused
_split = split


def load(path: str = FIGURES) -> dict:
    return _load(path)


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


def report(figures: dict, accounts: dict) -> dict:
    """What the plan reads after: its accounts, each partner, the opening."""
    karat = main_karat()
    watched = {k: balance(accounts[k].id) for k in figures['expect_after']}
    partners = {k: round(main_grams(balance(accounts[k].id), karat), 2) for k in figures['expect_partners_main']}
    w = main_grams(balance(accounts['capital_w'].id), karat) + main_grams(balance(accounts['opening_adjust_w'].id), karat)
    opening = round(-(w + balance(accounts['capital_c'].id)['cash'] / float(figures['count_price'])), 2)
    return {'accounts': watched, 'partners_main': partners, 'opening_main': opening}


def reorganize(*, by: str, now: dt.datetime, figures: dict | None = None) -> dict:
    """Write the plan's entries; refuse, writing nothing, when the books differ
    from it before or after. The caller commits (the CLI rolls back a dry run)."""
    figures = dict(figures or load())
    figures['groups'] = {'riyadh': figures['riyadh_shares']}
    done = write_plan(figures, by=by, now=now, check=lambda accounts: _opening_lines_differ(figures, accounts))
    accounts = done['accounts']
    if done['already']:
        return {'already': True, 'entries': done['entries'], 'after': report(figures, accounts)}

    after = report(figures, accounts)
    wrong = differ(figures['expect_after'], accounts)
    wrong += [f'{k}: {after["partners_main"][k]:,.2f} والخطة {float(v):,.2f}'
              for k, v in figures['expect_partners_main'].items() if abs(after['partners_main'][k] - float(v)) > 0.02]
    if abs(after['opening_main'] - float(figures['expect_opening_main'])) > 0.02:
        wrong.append(f'الافتتاح {after["opening_main"]:,.2f} والخطة {float(figures["expect_opening_main"]):,.2f}')
    if wrong:
        raise OpeningRefused('النتيجة غير ما تقوله الخطة: ' + '؛ '.join(wrong))

    made_key = figures['made_account']['key']
    entries = [{k: e[k] for k in ('key', 'entry', 'date')} for e in done['entries']]
    result = {'entries': entries, 'made_account': done['made'][made_key], 'after': after}
    AuditLog.log_action(user_name=by, action='repair_opening_2026', entity_type='JournalEntry',
                        entity_id=done['entries'][0]['id'], entity_number=figures['reference_type'],
                        details=json.dumps(result, ensure_ascii=False, default=str))
    return result
