"""The transition to the moving average: the new period starts with its stock right (ADR-042).

The owner (11 Oct 2026): «لا تصلح ما سبق فيما يخص قائمة الدخل ... السنة الجديدة
نبدأها بشكل سليم». The past's income statement stays as it was posted -- on
purchases, and it says so (cost_basis). One entry, dated the transition's first
instant, opens the new period on the replay (services/gold_cost):

  1300, 1310    the financial stock lands on the worked and the scrap pool's
                value -- weight x moving average, the opening gold at the
                opening price
  2100          its own balance cleared: the January-April 2026 supplier
                invoices wrote the gold's value in riyals on the suppliers'
                control account -- gold already owed, by weight, on 7210.
                Owed twice (6,228,280 on the 10 Oct copy)
  cash on a     cleared: an office reservation's price was written on the scrap
  pool's weight stock's weight account (stage-4 item 15; 634,899)
  account
  33            the difference: «فروقات تقييم الذهب» -- equity, not profit

No income-statement account moves. A back-dated entry before the transition
(a stage-4 repair dated as its document) moves the stock after the entry was
written: the next run writes the difference as a further entry, never an edit.
"""
from __future__ import annotations

import json
from collections import defaultdict
from datetime import date, datetime, time

from sqlalchemy import func, or_

from models import Account, AuditLog, JournalEntry, JournalEntryLine, db
from services.gold_cost import pool_accounts, replay

TRANSITION = 'gold_cost_transition'

# The transition's accounts, by role (CHART-002 release 5: they were 1300, 1310,
# 2100 and 33 here): the worked and scrap gold's stock, the suppliers' gold
# value (its own postings, not its suppliers'), the valuation equity.
WORKED_STOCK, SCRAP_STOCK = 'gold_inventory_new', 'gold_inventory_scrap'
SUPPLIERS_GOLD_VALUE = 'supplier_accounts_parent'
VALUATION_EQUITY = 'valuation_equity'
CENT = 0.005

PURCHASES_NOTE = ('تكلفة المبيعات على أساس المشتريات: يُحمَّل الذهب عند شرائه لا عند بيعه، '
                  'فالفترة التي تشتري أكثر مما تبيع تظهر أقل ربحًا من حقيقتها (ADR-042)')
AVERAGE_NOTE = 'تكلفة المبيعات بمتوسط تكلفة الذهب المتحرك: يُحمَّل الذهب عند بيعه بمتوسط تكلفته (ADR-042)'


class NotAsMeasured(ValueError):
    pass


def _role_account(role) -> Account:
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    return db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, role))


def _balances(account_ids, since, until) -> dict[int, float]:
    """{account id: cash debit - credit} of the counted lines in [since, until),
    the transition's own entries left out -- the books it found."""
    from accounting.balances import counted_line_filters
    q = (db.session.query(JournalEntryLine.account_id,
                          func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(account_ids or {-1}),
                 JournalEntry.date < datetime.combine(until, time.min),
                 or_(JournalEntry.reference_type.is_(None), JournalEntry.reference_type != TRANSITION)))
    if since is not None:
        q = q.filter(JournalEntry.date >= datetime.combine(since, time.min))
    return {i: float(v or 0) for i, v in q.group_by(JournalEntryLine.account_id).all()}


def _balanced(lines: dict, against: str) -> dict[str, float]:
    """The lines to the cent, *against* taking what balances them after the rounding."""
    out = {k: round(v, 2) for k, v in lines.items() if k != against and abs(v) > CENT}
    rest = round(-sum(out.values()), 2)
    if abs(rest) > CENT:
        out[against] = rest
    return out


def plan_transition(*, opening_price: float, at: date, since: date | None = None) -> dict:
    """The transition entry at *at* -- {account number: debit +, credit -} -- measured, not written."""
    r = replay(opening_price=opening_price, since=since, until=at)
    number = dict(Account.query.with_entities(Account.id, Account.account_number).all())
    worked_stock, scrap_stock = _role_account(WORKED_STOCK), _role_account(SCRAP_STOCK)
    worked, scrap, suppliers = {worked_stock.id}, {scrap_stock.id}, {_role_account(SUPPLIERS_GOLD_VALUE).id}
    pools = pool_accounts()
    pool_weight = pools['worked'] | pools['scrap']
    found = _balances(worked | scrap | suppliers | pool_weight, since, at)

    lines = defaultdict(float)
    lines[worked_stock.account_number] = r.pools['worked'].value - sum(v for i, v in found.items() if i in worked)
    lines[scrap_stock.account_number] = r.pools['scrap'].value - sum(v for i, v in found.items() if i in scrap)
    for account_id, amount in found.items():
        if account_id in suppliers | pool_weight:
            lines[number[account_id]] -= amount
    return {
        'at': at, 'date': datetime.combine(at, time.min), 'opening_price': opening_price,
        'lines': _balanced(lines, _role_account(VALUATION_EQUITY).account_number),
        'pools': {n: {'grams': round(p.weight, 3), 'value': round(p.value, 2), 'average': round(p.avg, 4)}
                  for n, p in r.pools.items()},
        'others': r.others,
    }


def _written() -> list[JournalEntry]:
    return (JournalEntry.query.filter(JournalEntry.reference_type == TRANSITION, JournalEntry.is_deleted.is_(False))
            .order_by(JournalEntry.id).all())


def _drift(entries: list[JournalEntry], lines: dict) -> dict[str, float]:
    """The plan's lines less what *entries* already wrote."""
    number = dict(Account.query.with_entities(Account.id, Account.account_number).all())
    had = defaultdict(float)
    for entry in entries:
        for l in entry.lines:
            if not l.is_deleted:
                had[number[l.account_id]] += float(l.cash_debit or 0) - float(l.cash_credit or 0)
    return {k: round(lines.get(k, 0.0) - had.get(k, 0.0), 2) for k in sorted(set(had) | set(lines))
            if abs(lines.get(k, 0.0) - had.get(k, 0.0)) > CENT}


def write_transition(*, by: str, now, opening_price: float, at: date, since: date | None = None,
                     dry_run: bool = True) -> dict:
    """Write the transition entry -- or, once written, what moved since as a
    further entry. Idempotent; dry_run (the default) writes nothing. Refused:
    a transition that is not a first day, or has not come; movements the
    replay could not place; another transition day, or another opening price."""
    from services.repair.entries import write_entry
    if at.day != 1:
        raise NotAsMeasured(f'the transition is a month\'s first day, not {at}')
    if at > now.date():
        raise NotAsMeasured(f'{at} has not come: the stock is measured once the period before it is over')
    plan = plan_transition(opening_price=opening_price, at=at, since=since)
    if plan['others']:
        raise NotAsMeasured(f'{len(plan["others"])} movements the replay could not place -- review them first')
    done = _written()
    if done and done[0].date != plan['date']:
        raise NotAsMeasured(f'the transition was written for {done[0].date:%Y-%m-%d}, not {at}')
    if done and f'{opening_price:.4f}' not in (done[0].reference_number or ''):
        raise NotAsMeasured(f'the transition was written at another opening price ({done[0].reference_number})')
    lines = _drift(done, plan['lines']) if done else plan['lines']
    out = {**plan, 'written': [], 'drift': lines if done else {}}
    if dry_run or not lines:
        return out

    account_id = dict(Account.query.with_entities(Account.account_number, Account.id).all())
    missing = sorted(set(lines) - set(account_id))
    if missing:
        raise NotAsMeasured(f'accounts {missing} not found')
    description = (f'افتتاح مخزون الذهب المالي بالمتوسط المتحرك في {at:%Y-%m-%d} (ADR-042)' if not done else
                   f'افتتاح مخزون الذهب المالي -- ما تحرّك قبل {at:%Y-%m-%d} بعد كتابته (ADR-042)')
    entry = write_entry(
        date=plan['date'], description=description, reference_type=TRANSITION, reference_id=None,
        reference_number=f'{at:%Y-%m-%d}@{opening_price:.4f}',
        lines=[{'account_id': account_id[num], 'description': description,
                **({'cash_debit': amount} if amount > 0 else {'cash_credit': -amount})}
               for num, amount in sorted(lines.items())],
        by=by, now=now, prefix='COR', safe_rows=False,
    )
    out['written'].append(entry.entry_number)
    db.session.add(AuditLog(user_name=by, action=TRANSITION, entity_type='journal_entry', entity_id=entry.id,
                            success=True, details=json.dumps({'lines': lines, 'pools': plan['pools'], 'at': at,
                                                              'opening_price': opening_price, 'now': now},
                                                             ensure_ascii=False, default=str)))
    db.session.flush()
    return out


def cost_basis(start: datetime, end: datetime) -> tuple[str, str]:
    """The basis of the cost of sales over [start, end): before the transition,
    'purchases' (the past as it was posted); from it, 'moving_average'; across
    it, 'mixed' -- with the day named."""
    first = (JournalEntry.query.filter(JournalEntry.reference_type == TRANSITION, JournalEntry.is_deleted.is_(False))
             .order_by(JournalEntry.date).first())
    if first is None or end <= first.date:
        return 'purchases', PURCHASES_NOTE
    if start >= first.date:
        return 'moving_average', AVERAGE_NOTE
    return 'mixed', (f'قبل {first.date:%Y-%m-%d}: {PURCHASES_NOTE} -- ومنه: {AVERAGE_NOTE}')
