"""The balance sheet: what the shop owns and owes on a day, in riyals and grams (REPORTS ت2-1, ADR-083).

From the tree, never an account's number: each root (assets, liabilities,
equity, by their roles) shows its groups -- the root's children, through a
root's only child (1 «الأصول» has only 11) -- in riyals from each group's
subtree and in grams (the main karat) from its weight twin's. The result,
not yet closed, is the revenues' and expenses' net credit, riyals and grams:
what the books say, so the sheet balances; the gram profit is a measure of
its own (the income statement, ت2-2). What no group holds is said apart:
riyals on a weight account (a finding), and whatever else a section's total
holds beyond its groups. The sheet checks itself: assets = liabilities +
equity + the result, in riyals and in grams; no riyals on a weight account.
A day counts whole.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Check, Column, Report

KARATS = (18, 21, 22, 24)
SECTIONS = (('assets', 'الأصول', 'assets_root', 1),
            ('liabilities', 'الخصوم', 'liabilities_root', -1),
            ('equity', 'حقوق الملكية', 'equity_root', -1))
RESULT_ROOTS = ('revenue_root', 'expenses_root')


def groups_of(root_id: int) -> list:
    """A root's groups: its children by number -- its only child's, when it has one."""
    from models import Account
    children = Account.query.filter(Account.parent_id == root_id).order_by(Account.account_number).all()
    if len(children) == 1:
        return groups_of(children[0].id)
    return children


def _balances(as_of: dt.date) -> dict:
    """{account id: (riyals debit - credit, grams of the main karat debit - credit)} to the end of *as_of*."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    from pricing.karat_service import convert_to_main_karat
    sums = [func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit)]
    sums += [func.sum(getattr(JournalEntryLine, f'debit_{k}k') - getattr(JournalEntryLine, f'credit_{k}k'))
             for k in KARATS]
    rows = (db.session.query(JournalEntryLine.account_id, *sums)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters(),
                    JournalEntry.date < dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min))
            .group_by(JournalEntryLine.account_id).all())
    return {account_id: (float(cash or 0.0),
                         sum(convert_to_main_karat(float(g or 0.0), k) for k, g in zip(KARATS, grams)))
            for account_id, cash, *grams in rows}


def balance_sheet(*, as_of: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from accounting.chart_tree import role_account_id, subtree_ids, twin_id
    from models import Account
    balances = _balances(as_of)
    twins = {i: m for i, m in Account.query.with_entities(Account.id, Account.memo_account_id) if m}

    def weight_side(money_ids, own_twin=None):
        """The grams' accounts of *money_ids*: their twins' subtrees, and the
        group's own twin's -- a supplier's grams sit on his account's twin
        (72100020 is 2100020's), not under the group's (2 Nov copy: 183.527 g)."""
        roots = {twins[i] for i in money_ids if i in twins} | ({own_twin} if own_twin else set())
        return subtree_ids(*roots) if roots else set()

    def cash(ids):
        return sum(balances.get(i, (0.0, 0.0))[0] for i in ids)

    def grams(ids):
        return sum(balances.get(i, (0.0, 0.0))[1] for i in ids)

    def line(**row):
        row.setdefault('drill', None)
        row.setdefault('style', None)
        for key, places in (('cash', 2), ('weight', 3)):
            if row.get(key) is not None:
                row[key] = round(row[key], places)
        return row

    rows, totals, stray_total = [], {}, collections.Counter()
    for key, label, role, sign in SECTIONS:
        root = role_account_id(role)
        twin = twin_id(root)
        money_ids = subtree_ids(root)
        weight_ids = weight_side(money_ids, twin) - money_ids
        rows.append(line(key=key, name=label, style='heading', cash=None, weight=None))
        shown_cash = shown_weight = 0.0
        for group in groups_of(root):
            group_money = subtree_ids(group.id)
            group_weight = weight_side(group_money) - group_money
            # its riyals are its money accounts' -- riyals on a weight account are said apart
            c, w = sign * cash(group_money), sign * grams(group_money | group_weight)
            if not any(i in balances for i in group_money | group_weight):
                continue
            shown_cash += c
            shown_weight += w
            rows.append(line(key=f'group_{group.id}', account_id=group.id, number=group.account_number,
                             name=group.name, cash=c, weight=w, drill={'kind': 'account', 'id': group.id}))
        stray = sign * cash(weight_ids)
        stray_total[key] = stray
        if abs(stray) >= 0.005:
            shown_cash += stray
            rows.append(line(key='riyals_on_weight', name='ريالات مقيّدة على حسابات وزنية', cash=stray, weight=None,
                             style='finding'))
        total_cash, total_weight = sign * cash(money_ids | weight_ids), sign * grams(money_ids | weight_ids)
        other_cash, other_weight = total_cash - shown_cash, total_weight - shown_weight
        if abs(other_cash) >= 0.005 or abs(other_weight) >= 0.0005:
            rows.append(line(key=f'{key}_other', name='أخرى، خارج المجموعات', cash=other_cash, weight=other_weight))
        if key == 'equity':
            result_ids = set().union(*(subtree_ids(role_account_id(r)) for r in RESULT_ROOTS))
            result_twins = set().union(*(subtree_ids(t) for t in (twin_id(role_account_id(r)) for r in RESULT_ROOTS)
                                         if t))
            stray_total['result'] = -cash(result_twins)
            result_cash, result_weight = -cash(result_ids | result_twins), -grams(result_ids | result_twins)
            rows.append(line(key='result', name='النتيجة حتى تاريخه، من الدفاتر (لم تُقفل)', cash=result_cash,
                             weight=result_weight))
            total_cash += result_cash
            total_weight += result_weight
        totals[key] = (total_cash, total_weight)
        rows.append(line(key=f'{key}_total', name=f'مجموع {label}', cash=total_cash, weight=total_weight,
                         style='subtotal'))

    right_cash = totals['liabilities'][0] + totals['equity'][0]
    right_weight = totals['liabilities'][1] + totals['equity'][1]
    rows.append(line(key='liabilities_and_equity', name='الخصوم وحقوق الملكية', cash=right_cash, weight=right_weight,
                     style='subtotal'))
    checks = [
        Check('balanced_cash', 'الأصول = الخصوم + حقوق الملكية (ريال)', abs(totals['assets'][0] - right_cash) < 0.005),
        Check('balanced_weight', 'الأصول = الخصوم + حقوق الملكية (وزن)',
              abs(totals['assets'][1] - right_weight) < 0.0005),
        Check('no_riyals_on_weight', 'لا ريالات على الحسابات الوزنية',
              all(abs(v) < 0.005 for v in stray_total.values())),
    ]
    columns = [Column('number', 'الحساب'), Column('name', 'البند'),
               Column('cash', 'ريال', 'money', signed=True), Column('weight', 'جم', 'grams', signed=True)]
    return Report(id='balance_sheet', title='الميزانية العمومية', basis='posted_entries', columns=columns, rows=rows,
                  totals={}, checks=checks, end=as_of, read_at=now)
