"""The income statement: riyals by the chart tree, grams by the gram profit's five layers (REPORTS ت2-2, ADR-083).

Riyals (moved from routes/reports.py as they were): revenue is group 4's
subtree, the cost of sales 51's, the operating expenses the rest of 5
(services/income_accounts); the lines that count; which months carry the
gold's cost at its moving average (ADR-042).

Grams: the owner, 4 Nov 2026, «ربح الجرام هو طبقات ربح الجرام الخمس» --
one definition, the weight close's engine (services/weight_position,
ADR-048): ① the riyals of what was sold that became gold, ② revenues,
③ weight expenses, ④ cash expenses, ⑤ what still waits (its sales' profit
and the price's move). The tree's weight income statement (74/75, a gram
bought from a customer a weight gain) went: the constitution's WPROFIT-001,
two bases (on the 2 Nov copy about 2,600 g against 20,809 g for the year),
closed by this one and its parity law (tests/test_report_income_statement.py).
"""
from __future__ import annotations

import datetime as dt

from services.reports.contract import Column, Report


def tree_income(start: dt.date, end: dt.date) -> dict:
    """The riyal side, per account: {'revenue', 'cost_of_sales', 'operating':
    [{'account_code', 'account_name', 'account_id', 'amount'}], 'cost_basis',
    'cost_basis_note', 'wage'} -- the end day whole."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from accounting.wages import manufacturing_wage_expense_account_id
    from models import Account, JournalEntry, JournalEntryLine, db
    from services.gold_cost_books import cost_basis
    from services.income_accounts import income_account_groups
    lo = dt.datetime.combine(start, dt.time.min)
    hi = dt.datetime.combine(end + dt.timedelta(days=1), dt.time.min)
    groups = income_account_groups()
    wanted = groups['revenue'] | groups['cost_of_sales'] | groups['operating']
    sums = (db.session.query(JournalEntryLine.account_id,
                             func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
                             func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.date >= lo, JournalEntry.date < hi)
            .filter(*counted_line_filters())
            .filter(JournalEntryLine.account_id.in_(wanted or {-1}))
            .group_by(JournalEntryLine.account_id).all())
    accounts = {a.id: a for a in Account.query.filter(Account.id.in_([r[0] for r in sums] or [-1]))}
    out = {'revenue': [], 'cost_of_sales': [], 'operating': []}
    for account_id, debit, credit in sums:
        if account_id in groups['revenue']:
            group, amount = 'revenue', float(credit) - float(debit)
        else:
            group = 'cost_of_sales' if account_id in groups['cost_of_sales'] else 'operating'
            amount = float(debit) - float(credit)
        if abs(amount) < 0.005:
            continue
        account = accounts[account_id]
        out[group].append({'account_code': account.account_number, 'account_name': account.name,
                           'account_id': account_id, 'amount': round(amount, 2)})
    for group in out.values():
        group.sort(key=lambda d: d['account_code'])
    wage_id = manufacturing_wage_expense_account_id()
    out['wage'] = next((d for d in out['cost_of_sales'] if d['account_id'] == wage_id), None)
    out['cost_basis'], out['cost_basis_note'] = cost_basis(lo, hi)
    return out


def income_statement(*, start: dt.date, end: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from services.weight_position import performance
    tree = tree_income(start, end)
    rows = []

    def row(key, name, cash=None, weight=None, style=None, account=None):
        rows.append({'key': key, 'name': name, 'number': account['account_code'] if account else None,
                     'account_id': account['account_id'] if account else None,
                     'cash': round(cash, 2) if cash is not None else None,
                     'weight': round(weight, 3) if weight is not None else None, 'style': style,
                     'drill': {'kind': 'account', 'id': account['account_id']} if account else None})

    totals = {}
    for group, label, total_label in (('revenue', 'الإيرادات', 'مجموع الإيرادات'),
                                      ('cost_of_sales', 'تكلفة المبيعات', 'مجموع تكلفة المبيعات'),
                                      ('operating', 'المصاريف التشغيلية', 'مجموع المصاريف التشغيلية')):
        row(group, label, style='heading')
        for d in tree[group]:
            row(f'account_{d["account_id"]}', d['account_name'], cash=d['amount'], account=d)
        totals[group] = sum(d['amount'] for d in tree[group])
        row({'revenue': 'revenue_total', 'cost_of_sales': 'cost_of_sales_total',
             'operating': 'operating_total'}[group], total_label, cash=totals[group], style='subtotal')
        if group == 'cost_of_sales':
            row('gross_profit', 'مجمل الربح', cash=totals['revenue'] - totals['cost_of_sales'], style='subtotal')
    net = totals['revenue'] - totals['cost_of_sales'] - totals['operating']
    row('net_profit', 'صافي الربح', cash=net, style='subtotal')
    if tree['cost_basis_note']:
        row('cost_basis', tree['cost_basis_note'], style='note')

    gram = performance(start, end)
    layers = gram['layers']
    row('gram_layers', 'ربح الجرام — الطبقات الخمس', style='heading')
    for key, name, grams in (
            ('layer_trading', '① المتاجرة: ريالات المُباع التي عادت ذهبًا', layers['trading']),
            ('layer_revenue', '② الإيرادات', layers['revenue_converted'] + layers['revenue_direct']),
            ('layer_expense_direct', '③ المصاريف الوزنية', layers['expense_direct']),
            ('layer_expense_cash', '④ المصاريف النقدية', layers['expense_cash']),
            ('layer_waiting', '⑤ ما لم يُسكَّر بعد', layers['price_effect'])):
        row(key, name, weight=grams)
    parts = gram.get('price_effect_parts') or {}
    if parts:
        row('waiting_sales', 'منه ربح مبيعات تنتظر', weight=parts['waiting_sales'], style='note')
        row('waiting_price', 'ومنه أثر السعر', weight=parts['price'], style='note')
    row('gram_profit', 'صافي ربح الجرام', weight=gram['weight_profit'], style='subtotal')
    if gram.get('valuation_price'):
        row('valuation', f'ما ينتظر مقيّم بسعر التسكير {gram["valuation_price"]:,.2f} للجرام', style='note')

    columns = [Column('number', 'الحساب'), Column('name', 'البند'),
               Column('cash', 'ريال', 'money', signed=True), Column('weight', 'جم', 'grams', signed=True)]
    return Report(id='income_statement', title='قائمة الدخل', basis='posted_entries', columns=columns, rows=rows,
                  totals={}, start=start, end=end, read_at=now)
