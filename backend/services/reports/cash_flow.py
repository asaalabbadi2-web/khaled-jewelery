"""The cash flow: where the riyals came from and where they went, by the direct method (REPORTS ت2-3, ADR-083).

Cash is «النقدية والبنوك», the cash role's parent, and its whole subtree --
the safes, the banks, the employees' cash custody. Each counted entry that
moves it gives that cash to the accounts on its other side, each by its own
net (an entry balances: the cash it moves is its other lines' net), so a
transfer between two cash accounts moves none. The other side says the
activity and the line, by the tree, never a number: financing is equity;
investing the assets' groups that do not hold the cash (the non-current --
none in 2026's chart, said so); operating the rest; each line a root's group
(through a root's only child), its weight twins with it. The flow checks
itself: the cash before the period + the flow = the cash at its end.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Check, Column, Report

ROOTS = (('assets', 'assets_root'), ('liabilities', 'liabilities_root'), ('equity', 'equity_root'),
         ('revenue', 'revenue_root'), ('expenses', 'expenses_root'))
ACTIVITIES = (('operating', 'التدفق من التشغيل'), ('investing', 'التدفق من الاستثمار'),
              ('financing', 'التدفق من التمويل'))


def cash_ids() -> set:
    """«النقدية والبنوك»: the cash role's parent and its subtree."""
    from accounting.chart_tree import CASH_ROOT, role_account_id, subtree_ids
    from models import Account, db
    cash = db.session.get(Account, role_account_id(CASH_ROOT))
    return subtree_ids(cash.parent_id or cash.id)


def _lines_by_group(cash: set) -> tuple[dict, dict]:
    """{account id: (activity, group)}, {group id: group} -- every account under a
    root's group, its weight twins with it."""
    from accounting.chart_tree import role_account_id, subtree_ids
    from models import Account
    from services.reports.balance_sheet import groups_of
    twins = {i: m for i, m in Account.query.with_entities(Account.id, Account.memo_account_id) if m}
    where, groups = {}, {}
    for key, role in ROOTS:
        root = role_account_id(role)
        for group in groups_of(root):
            money = subtree_ids(group.id)
            weight = subtree_ids(*{twins[i] for i in money if i in twins}) if any(i in twins for i in money) else set()
            if key == 'equity':
                activity = 'financing'
            elif key == 'assets' and not (money & cash):
                # an assets group holding no cash: its first child chain is the current
                # assets' -- groups_of goes through a root's only child, so in 2026's
                # chart every group is under 11 «الأصول المتداولة»
                activity = 'investing' if _non_current(root, group.id, cash) else 'operating'
            else:
                activity = 'operating'
            groups[group.id] = group
            for i in money | weight:
                where.setdefault(i, (activity, group.id))
    return where, groups


def _non_current(root_id: int, group_id: int, cash: set) -> bool:
    """An assets group is non-current when it is a root's child beside the one holding the cash."""
    from accounting.chart_tree import subtree_ids
    from models import Account
    children = [a.id for a in Account.query.filter(Account.parent_id == root_id)]
    holding = [c for c in children if subtree_ids(c) & cash]
    return group_id in children and group_id not in holding


def _cash_balance(cash: set, before: dt.datetime) -> float:
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    value = (db.session.query(func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(cash or {-1}),
                     JournalEntry.date < before).scalar())
    return float(value or 0.0)


def cash_flow(*, start: dt.date, end: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015). The end day counts whole."""
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    lo = dt.datetime.combine(start, dt.time.min)
    hi = dt.datetime.combine(end + dt.timedelta(days=1), dt.time.min)
    cash = cash_ids()
    moving = (db.session.query(JournalEntry.id)
              .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
              .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(cash or {-1}),
                      JournalEntry.date >= lo, JournalEntry.date < hi,
                      (JournalEntryLine.cash_debit != 0) | (JournalEntryLine.cash_credit != 0))
              .distinct())
    others = (db.session.query(JournalEntryLine.account_id, JournalEntryLine.cash_credit - JournalEntryLine.cash_debit)
              .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
              .filter(*counted_line_filters(), JournalEntryLine.journal_entry_id.in_(moving),
                      JournalEntryLine.account_id.notin_(cash or {-1})).all())
    where, groups = _lines_by_group(cash)
    flows = collections.defaultdict(lambda: [0.0, 0.0])          # (activity, group id | None) -> [in, out]
    for account_id, value in others:
        value = float(value or 0.0)
        if abs(value) < 0.005:
            continue
        key = where.get(account_id, ('operating', None))
        flows[key][0 if value > 0 else 1] += abs(value)

    rows, net_change = [], 0.0

    def row(key, name, inflow=None, outflow=None, net=None, style=None, group=None):
        rows.append({'key': key, 'name': name, 'number': group.account_number if group else None,
                     'account_id': group.id if group else None,
                     'inflow': round(inflow, 2) if inflow is not None else None,
                     'outflow': round(outflow, 2) if outflow is not None else None,
                     'net': round(net, 2) if net is not None else None, 'style': style,
                     'drill': {'kind': 'account', 'id': group.id} if group else None})

    for activity, label in ACTIVITIES:
        row(activity, label, style='heading')
        lines = sorted(((g, v) for (a, g), v in flows.items() if a == activity), key=lambda x: -(x[1][0] + x[1][1]))
        total_in = total_out = 0.0
        for group_id, (inflow, outflow) in lines:
            group = groups.get(group_id)
            row(f'{activity}_{group_id}', group.name if group else 'أخرى، خارج المجموعات', inflow, outflow,
                inflow - outflow, group=group)
            total_in += inflow
            total_out += outflow
        if not lines:
            row(f'{activity}_none', 'لا حركة', style='note')
        row(f'{activity}_total', f'صافي {label}', total_in, total_out, total_in - total_out, style='subtotal')
        net_change += total_in - total_out

    opening, closing = _cash_balance(cash, lo), _cash_balance(cash, hi)
    row('net_change', 'صافي التغيّر في النقد', net=net_change, style='subtotal')
    row('opening', 'النقد أول الفترة', net=opening)
    row('closing', 'النقد آخر الفترة', net=closing, style='subtotal')
    checks = [Check('flow_closes', 'النقد أول الفترة + صافي التدفق = النقد آخرها',
                    abs(opening + net_change - closing) < 0.005)]
    columns = [Column('number', 'الحساب'), Column('name', 'البند'), Column('inflow', 'داخل', 'money'),
               Column('outflow', 'خارج', 'money'), Column('net', 'الصافي', 'money', signed=True)]
    return Report(id='cash_flow', title='التدفقات النقدية', basis='posted_entries', columns=columns, rows=rows,
                  totals={}, checks=checks, start=start, end=end, read_at=now)
