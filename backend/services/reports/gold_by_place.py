"""The shop's gold by its place on a day: the balance sheet's assets in grams, place by place (REPORTS ت5-2, ADR-083).

The owner, 4 Nov 2026 («الذهب حسب مكانه»): «مركز الذهب» summed every
account's weight -- assets and liabilities alike -- into a «short position»
of -5,147 g on the 2 Nov copy, where the balance sheet's assets held
42,509 g, balanced: a figure with no meaning. This reads the assets' grams as
the balance sheet does (balance_sheet.weight_accounts: each group's money
accounts and their weight twins) and lists, under each group, every account
that holds gold -- a safe by its own name -- its grams of each karat as they
are, and in the main karat. What no group holds is said apart. Under the
customers' group a note says what its grams are: the weight memo twins'
dual-system weights, not gold at the customers (CUSTGOLD-001). Its total is
the balance sheet's assets in grams: the check reads the sheet itself. A note
values the total at today's office price, saying the price and its time --
none when no price is recorded. A day counts whole.
"""
from __future__ import annotations

import datetime as dt

from services.reports.contract import Check, Column, Report

KARATS = (24, 22, 21, 18)
EPS = 0.0005


def _grams(as_of: dt.date) -> dict:
    """{account id: {karat: grams debit - credit}} to the end of *as_of*."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    rows = (db.session.query(JournalEntryLine.account_id,
                             *(func.sum(getattr(JournalEntryLine, f'debit_{k}k')
                                        - getattr(JournalEntryLine, f'credit_{k}k')) for k in KARATS))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters(),
                    JournalEntry.date < dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min))
            .group_by(JournalEntryLine.account_id).all())
    return {account_id: {k: float(g or 0.0) for k, g in zip(KARATS, grams)} for account_id, *grams in rows}


def gold_by_place(*, as_of: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from accounting.chart_tree import ASSETS_ROOT, role_account_id, subtree_ids, twin_id
    from models import Account, Customer, SafeBox, db
    from pricing.karat_service import convert_to_main_karat
    from services.reports.balance_sheet import balance_sheet, groups_of, weight_accounts
    grams = _grams(as_of)
    twins = {i: m for i, m in Account.query.with_entities(Account.id, Account.memo_account_id) if m}
    safes = {a: n for a, n in SafeBox.query.with_entities(SafeBox.account_id, SafeBox.name) if a}
    root = role_account_id(ASSETS_ROOT)
    money = subtree_ids(root)
    places = money | (weight_accounts(money, twin_id(root), twins) - money)

    def main(by_karat):
        return sum(convert_to_main_karat(g, k) for k, g in by_karat.items())

    def holding(ids):
        return sorted((i for i in ids if i in grams and any(abs(g) > EPS for g in grams[i].values())),
                      key=lambda i: -main(grams[i]))

    rows, shown = [], set()

    def section(name, ids, group=None):
        held = holding(ids)
        if not held:
            return
        rows.append({'name': name, 'number': group.account_number if group else None, 'style': 'heading',
                     'main': round(sum(main(grams[i]) for i in held), 3)})
        for i in held:
            account = db.session.get(Account, i)
            rows.append({'account_id': i, 'number': account.account_number if account else None,
                         'name': safes.get(i) or (account.name if account else str(i)),
                         **{f'k{k}': round(grams[i][k], 3) or None for k in KARATS},
                         'main': round(main(grams[i]), 3), 'drill': {'kind': 'account', 'id': i}})
        shown.update(held)

    customers = {a for (a,) in Customer.query.with_entities(Customer.account_id) if a}
    for group in groups_of(root):
        group_money = subtree_ids(group.id)
        before = len(rows)
        section(group.name, group_money | (weight_accounts(group_money, twins=twins) - group_money), group)
        if customers & group_money and len(rows) > before:
            rows.append({'name': 'جرامات حسابات العملاء الوزنية أوزانُ النظام المزدوج، لا ذهبٌ عند العملاء '
                                 '(CUSTGOLD-001؛ «أرصدة العملاء» لا تجد عميلًا مدينًا بذهب)', 'style': 'note'})
    section('أخرى، خارج المجموعات', places - shown)

    held = holding(places)
    totals = {f'k{k}': round(sum(grams[i][k] for i in held), 3) for k in KARATS}
    totals['main'] = round(sum(main(grams[i]) for i in held), 3)

    sheet = balance_sheet(as_of=as_of, now=now)
    assets = next(r['weight'] for r in sheet.rows if r.get('key') == 'assets_total')
    checks = [Check('the_balance_sheet_s', 'المجموع = أصول الميزانية بالوزن', abs(totals['main'] - assets) < 0.001)]

    from pricing.gold_price_service import get_current_gold_price, get_main_karat
    price = get_current_gold_price()
    karat = get_main_karat()
    if price.get('source') != 'fallback' and price.get('price_per_gram_main_karat'):
        per_gram = float(price['price_per_gram_main_karat'])
        rows.append({'name': f'قيمتها بسعر اليوم ({per_gram:,.2f} ريال لجرام عيار {karat}، '
                             f'{str(price.get("updated_at") or "")[:16].replace("T", " ")}): '
                             f'{totals["main"] * per_gram:,.2f} ريال',
                     'style': 'note'})
    else:
        rows.append({'name': 'لا سعر مسجّل للذهب: لا قيمة بالريال', 'style': 'note'})

    columns = [Column('number', 'الحساب'), Column('name', 'المكان'),
               *(Column(f'k{k}', f'عيار {k}', 'grams', signed=True) for k in KARATS),
               Column('main', f'بعيار {karat}', 'grams', signed=True)]
    return Report(id='gold_by_place', title='الذهب حسب مكانه', basis='posted_entries', columns=columns, rows=rows,
                  totals=totals, checks=checks, end=as_of, read_at=now)
