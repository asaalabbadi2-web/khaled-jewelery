"""Customers' balances on a day, in riyals and in grams, from the ledger (REPORTS ت5-1, ADR-083).

The owner, 4 Nov 2026 («يقرأ الدفتر الصحيح»): the old «أرصدة ذهب العملاء»
read the customers' weight memo twins (712…), which hold the dual system's
weights -- 18,805 g «owed» by 21 customers on the 2 Nov copy, where the
ledger finds none. This reads the ledger's one reader of a customer's balance
(services/party_live_balances.compute_live_customer_balances, BALANCE-001 B1:
every line on its own account, tagged or not, and those tagged to it on a
shared customer account -- cash, and the gold columns of the same lines; the
memo twin never). Each customer owing or owed, positive when it owes the shop,
its grams in the main karat. What the receivables group holds that no
customer does -- a line on a shared account tagged to nobody -- is said apart,
and the check says there is none. A day counts whole.
"""
from __future__ import annotations

import datetime as dt

from services.reports.contract import Check, Column, Report

KARATS = (18, 21, 22, 24)
EPS = {'cash': 0.005, 'gold': 0.0005}


def _main(row) -> float:
    from pricing.karat_service import convert_to_main_karat
    return sum(convert_to_main_karat(float(row.get(f'{k}k') or 0.0), k) for k in KARATS)


def _group(before) -> tuple[float, float]:
    """The receivables group's riyals and main-karat grams, every counted line on its subtree."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT, role_subtree_ids
    from models import JournalEntry, JournalEntryLine, db
    row = (db.session.query(func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit),
                            *(func.sum(getattr(JournalEntryLine, f'debit_{k}k')
                                       - getattr(JournalEntryLine, f'credit_{k}k')) for k in KARATS))
           .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
           .filter(*counted_line_filters(), JournalEntry.date < before,
                   JournalEntryLine.account_id.in_(role_subtree_ids(CUSTOMER_RECEIVABLES_ROOT) or {-1})).one())
    return float(row[0] or 0.0), _main({f'{k}k': v for k, v in zip(KARATS, row[1:])})


def customer_balances(*, as_of: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from models import Customer
    from services.party_live_balances import compute_live_customer_balances
    before = dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min)
    customers = Customer.query.order_by(Customer.name).all()
    balances = compute_live_customer_balances(customers, before)
    rows, cash_total, gold_total = [], 0.0, 0.0
    for c in customers:
        b = balances.get(c.id) or {}
        cash, gold = float(b.get('cash') or 0.0), _main(b)
        if abs(cash) < EPS['cash'] and abs(gold) < EPS['gold']:
            continue
        cash_total += cash
        gold_total += gold
        rows.append({'code': c.customer_code, 'name': c.name, 'cash': round(cash, 2) or 0.0,
                     'gold': round(gold, 3) or 0.0, 'drill': {'kind': 'customer', 'id': c.id}})
    rows.sort(key=lambda r: -abs(r['cash']))
    group_cash, group_gold = _group(before)
    apart_cash, apart_gold = group_cash - cash_total, group_gold - gold_total
    held = abs(apart_cash) < EPS['cash'] and abs(apart_gold) < EPS['gold']
    if not held:
        rows.append({'name': 'على حسابات العملاء المشتركة بلا عميل', 'style': 'finding',
                     'cash': round(apart_cash, 2), 'gold': round(apart_gold, 3)})
    columns = [Column('code', 'الكود'), Column('name', 'العميل'), Column('cash', 'الرصيد (ريال)', 'money', signed=True),
               Column('gold', 'الذهب (جم)', 'grams', signed=True)]
    checks = [Check('every_line_has_its_customer', 'كل سطر على حسابات العملاء له عميل', held)]
    return Report(id='customer_balances', title='أرصدة العملاء', basis='posted_entries', columns=columns, rows=rows,
                  totals={'cash': round(group_cash, 2), 'gold': round(group_gold, 3)}, checks=checks,
                  end=as_of, read_at=now)
