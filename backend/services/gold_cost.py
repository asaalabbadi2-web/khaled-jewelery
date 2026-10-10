"""What the gold cost -- two pools at their moving average, replayed from the books (ADR-042, phase 1).

Measurement only: reads the posted entries, writes nothing. The owner (11 Oct
2026) chose a perpetual cost by weight with two pools -- scrap (the scrap
safes, the custodies, the offices' and suppliers' gold accounts: what is with
an office counts in, what we owe a supplier counts out) and worked (the
display) -- and approved the rule for a pool below zero. This replays every
movement into or out of a pool, in date order, and says each day's weight,
value and average, and each month's cost of what was sold.

A pool is two numbers: its weight (main-karat grams -- karats by equivalence,
so 21 g of 18k in and 18 g of 21k out leaves it unchanged) and its value. The
weight follows the books; the value moves only when gold enters for money or
leaves by a sale:

  purchase     weight in with a cash debit on a purchase account (512's
               subtree, or the scrap inventory 1310 before April) -- value in
               at the price; an office reservation's transfer, at the
               reservation's amount
  transfer     the two pools moving opposite (a supplier's gold for gold) --
               value moves at the average of the pool it leaves
  sale         weight out to customers (or, in the early sales, against the
               sales' weight twin) -- value out at the average: the cost of
               what was sold
  opening      against equity -- value at the opening price (a policy, given)
  correction   reversals and historical reconciliations -- at the average,
  other        the rest -- at the average; both said, for review

Below zero (the owner, 11 Oct 2026): a short pool is valued at its average when
it went short; gold bought while it is short covers the short first, at its
price, and the difference between the two goes to «فروق تكلفة تبادل الذهب».
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime

from sqlalchemy import func

from models import Account, Invoice, JournalEntry, JournalEntryLine, OfficeReservation, db

MAIN_KARAT = 21.0
KARATS = (18, 21, 22, 24)

# Which accounts are which pool -- by the tree (a policy: data, not law).
WORKED_ROOTS = ('71300',)
SCRAP_ROOTS = ('71310', '7210')
PURCHASE_CASH_ROOTS = ('512', '1310')    # where a purchase's price is debited
CUSTOMER_ROOTS = ('7120',)
SALES_TWIN_ROOTS = ('74',)               # the sales' weight twins (early sales wrote these)
EQUITY_ROOTS = ('73',)
CORRECTION_TYPES = ('journal_entry_reversal', 'balance_correction', 'voucher_reversal')
OFFICE_TRANSFER = 'office_reservation_weight_transfer'
EPS = 0.0005


@dataclass
class Pool:
    weight: float = 0.0
    value: float = 0.0
    last_avg: float = 0.0

    @property
    def avg(self) -> float:
        return self.value / self.weight if abs(self.weight) > EPS else self.last_avg

    def _settle(self):
        if abs(self.weight) > EPS:
            self.last_avg = self.value / self.weight

    def take(self, grams: float) -> float:
        """Grams out at the average; the value they take."""
        out = grams * self.avg
        self.weight -= grams
        self.value -= out
        self._settle()
        return out

    def put(self, grams: float, value: float) -> float:
        """Grams in at *value*. Covering a short first at the short's average;
        returns the exchange difference (paid above the short's value)."""
        diff = 0.0
        if self.weight < -EPS and grams > 0:
            covered = min(grams, -self.weight)
            price = value / grams if grams else 0.0
            diff = covered * (price - self.avg)
        self.weight += grams
        self.value += value - diff
        self._settle()
        return diff


@dataclass
class Month:
    purchases_g: float = 0.0
    purchases_value: float = 0.0
    sold_worked_g: float = 0.0
    cost_of_worked_sold: float = 0.0
    sold_scrap_g: float = 0.0
    cost_of_scrap_sold: float = 0.0
    transfers_g: float = 0.0
    exchange_difference: float = 0.0
    corrections_g: float = 0.0
    corrections_value: float = 0.0
    other_g: float = 0.0
    other_value: float = 0.0
    opening_g: float = 0.0
    opening_value: float = 0.0


@dataclass
class Replay:
    days: list = field(default_factory=list)       # (date, {pool: (weight, value, avg)})
    months: dict = field(default_factory=dict)     # 'YYYY-MM' -> Month
    others: list = field(default_factory=list)     # unclassified entries, for review
    pools: dict = field(default_factory=dict)


def _subtree_ids(roots) -> set[int]:
    rows = Account.query.with_entities(Account.id, Account.parent_id, Account.account_number).all()
    children, by_number = defaultdict(list), {}
    for i, p, n in rows:
        by_number[str(n or '').strip()] = i
        if p is not None:
            children[p].append(i)
    found = set()
    stack = [by_number[r] for r in roots if r in by_number]
    while stack:
        node = stack.pop()
        if node not in found:
            found.add(node)
            stack.extend(children.get(node, ()))
    return found


def _grams(line) -> float:
    return sum((float(getattr(line, f'debit_{k}k') or 0) - float(getattr(line, f'credit_{k}k') or 0)) * k / MAIN_KARAT
               for k in KARATS)


def replay(*, opening_price: float, since: date | None = None, until: date | None = None) -> Replay:
    """Replay every posted movement of the two pools, oldest first."""
    from accounting.balances import counted_line_filters
    worked, scrap = _subtree_ids(WORKED_ROOTS), _subtree_ids(SCRAP_ROOTS)
    cash_accounts = _subtree_ids(PURCHASE_CASH_ROOTS)
    customers, equity = _subtree_ids(CUSTOMER_ROOTS), _subtree_ids(EQUITY_ROOTS)
    sales_twin = _subtree_ids(SALES_TWIN_ROOTS)
    pool_ids = worked | scrap

    touched = (db.session.query(JournalEntryLine.journal_entry_id)
               .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
               .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(pool_ids)))
    if since is not None:
        touched = touched.filter(JournalEntry.date >= datetime.combine(since, datetime.min.time()))
    if until is not None:
        touched = touched.filter(JournalEntry.date < datetime.combine(until, datetime.min.time()))
    entry_ids = {r[0] for r in touched.distinct().all()}
    entries = (JournalEntry.query.filter(JournalEntry.id.in_(entry_ids or {-1}))
               .order_by(JournalEntry.date, JournalEntry.id).all())
    lines_by_entry = defaultdict(list)
    for line in (JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entry_ids or {-1}),
                                               JournalEntryLine.is_deleted.is_(False)).all()):
        lines_by_entry[line.journal_entry_id].append(line)

    # An office reservation's transfer is valued at the reservation's amount.
    reservation_price = {}
    transfers = [e for e in entries if e.reference_type == OFFICE_TRANSFER]
    if transfers:
        wgt = {e.id: e.reference_id for e in JournalEntry.query.filter(
            JournalEntry.id.in_([t.reference_id for t in transfers])).all()}
        res = {r.id: r for r in OfficeReservation.query.filter(OfficeReservation.id.in_(set(wgt.values()))).all()}
        for t in transfers:
            r = res.get(wgt.get(t.reference_id))
            if r is not None:
                reservation_price[t.id] = float(r.total_amount or 0.0)

    # The month a correction belongs to: its document's (an invoice's date, or
    # the reversed entry's), not the day it was written.
    corrected_month = {}
    inv_refs = {e.id: e.reference_id for e in entries if e.reference_type == 'invoice'}
    rev_refs = {e.id: e.reference_id for e in entries if e.reference_type == 'journal_entry_reversal'}
    if inv_refs:
        dates = dict(db.session.query(Invoice.id, Invoice.date).filter(Invoice.id.in_(set(inv_refs.values()))).all())
        corrected_month.update({k: dates[v].strftime('%Y-%m') for k, v in inv_refs.items() if dates.get(v)})
    if rev_refs:
        dates = dict(db.session.query(JournalEntry.id, JournalEntry.date)
                     .filter(JournalEntry.id.in_(set(rev_refs.values()))).all())
        corrected_month.update({k: dates[v].strftime('%Y-%m') for k, v in rev_refs.items() if dates.get(v)})

    pools = {'scrap': Pool(), 'worked': Pool()}
    out = Replay(pools=pools)
    current_day = None

    def month(e) -> Month:
        return out.months.setdefault(e.date.strftime('%Y-%m'), Month())

    def snapshot(day):
        out.days.append((day, {n: (round(p.weight, 3), round(p.value, 2), round(p.avg, 2)) for n, p in pools.items()}))

    for e in entries:
        day = e.date.date()
        if current_day is not None and day != current_day:
            snapshot(current_day)
        current_day = day
        lines = lines_by_entry[e.id]
        d = {'scrap': sum(_grams(l) for l in lines if l.account_id in scrap),
             'worked': sum(_grams(l) for l in lines if l.account_id in worked)}
        if all(abs(v) < EPS for v in d.values()):
            continue
        m = month(e)
        accounts = {l.account_id for l in lines if abs(_grams(l)) > EPS or l.cash_debit or l.cash_credit}
        cash_price = sum(float(l.cash_debit or 0) for l in lines if l.account_id in cash_accounts)

        # transfer: the pools move opposite each other (a supplier's gold for gold)
        if d['scrap'] * d['worked'] < 0:
            src, dst = ('scrap', 'worked') if d['worked'] > 0 else ('worked', 'scrap')
            moved = min(abs(d['scrap']), abs(d['worked']))
            value = pools[src].take(moved)
            m.exchange_difference += pools[dst].put(moved, value)
            m.transfers_g += moved
            rest = {k: v - (moved if v > 0 else -moved) for k, v in d.items()}
        else:
            rest = d
        for name, grams in rest.items():
            if abs(grams) < EPS:
                continue
            pool = pools[name]
            if e.reference_type == OFFICE_TRANSFER and grams > 0 and e.id in reservation_price:
                price = reservation_price[e.id]
                m.exchange_difference += pool.put(grams, price)
                m.purchases_g += grams
                m.purchases_value += price
            elif grams > 0 and cash_price > 0:
                m.exchange_difference += pool.put(grams, cash_price)
                m.purchases_g += grams
                m.purchases_value += cash_price
            elif accounts & equity:
                value = grams * opening_price
                pool.put(grams, value)
                m.opening_g += grams
                m.opening_value += value
            elif grams < 0 and accounts & (customers | sales_twin) and e.reference_type not in CORRECTION_TYPES:
                cost = pool.take(-grams)
                if name == 'worked':
                    m.sold_worked_g += -grams
                    m.cost_of_worked_sold += cost
                else:
                    m.sold_scrap_g += -grams
                    m.cost_of_scrap_sold += cost
            elif (e.reference_type in CORRECTION_TYPES or 'تسوية تاريخية' in (e.description or '')
                  or (grams > 0 and accounts & customers)):
                # A reversal, a historical reconciliation or a sale return: at the
                # average. Gold coming back to a pool undoes a sale -- it lowers the
                # cost of what was sold, in the month of the document it corrects
                # (a rejected sale reversed in August, the January-April weights
                # given back on 13 June); the average follows the dates as they are.
                if grams > 0:
                    value = grams * pool.avg
                    pool.put(grams, value)
                else:
                    value = -pool.take(-grams)
                target = out.months.setdefault(corrected_month.get(e.id, e.date.strftime('%Y-%m')), Month())
                if grams > 0 and name == 'worked':
                    target.sold_worked_g -= grams
                    target.cost_of_worked_sold -= value
                elif grams > 0:
                    target.sold_scrap_g -= grams
                    target.cost_of_scrap_sold -= value
                target.corrections_g += grams
                target.corrections_value += value
            else:
                if grams > 0:
                    pool.put(grams, grams * pool.avg)
                    value = grams * pool.avg
                else:
                    value = -pool.take(-grams)
                m.other_g += grams
                m.other_value += value
                out.others.append({'entry': e.entry_number, 'date': day, 'pool': name, 'grams': round(grams, 3),
                                   'reference': f'{e.reference_type}:{e.reference_id}',
                                   'description': (e.description or '')[:80]})
    if current_day is not None:
        snapshot(current_day)
    return out


def ledger_weights() -> dict:
    """Each pool's weight as the books say it -- the replay must end on it."""
    from accounting.balances import counted_line_filters
    result = {}
    for name, roots in (('scrap', SCRAP_ROOTS), ('worked', WORKED_ROOTS)):
        ids = _subtree_ids(roots)
        expr = sum((func.coalesce(func.sum(getattr(JournalEntryLine, f'debit_{k}k')), 0.0)
                    - func.coalesce(func.sum(getattr(JournalEntryLine, f'credit_{k}k')), 0.0)) * k / MAIN_KARAT
                   for k in KARATS)
        result[name] = float(db.session.query(expr).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                             .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(ids or {-1})).scalar() or 0.0)
    return result


def market_average_price(start: date, days: int = 30) -> tuple[float, date, date]:
    """The opening price when none is entered (the owner, 11 Oct 2026: «يدخل
    يدويًا بمتوسط السنة السابقة إن وُجد، وإلا فمن متوسط سعر السوق»): the
    average market price per main-karat gram over *days* from the first price
    on or after *start* -- the price history begins after the books do.
    Returns (price, first day, last day) so the run says which window it used."""
    from datetime import timedelta
    from models import GoldPrice
    from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
    first = (db.session.query(func.min(GoldPrice.date))
             .filter(GoldPrice.date >= datetime.combine(start, datetime.min.time()), GoldPrice.price > 0).scalar())
    if first is None:
        raise ValueError('no market price recorded on or after the opening date')
    last = first + timedelta(days=days)
    usd_per_oz = float(db.session.query(func.avg(GoldPrice.price))
                       .filter(GoldPrice.date >= first, GoldPrice.date < last, GoldPrice.price > 0).scalar())
    per_gram_24k = usd_per_oz / TROY_OZ_TO_GRAMS * SAR_USD_PEG
    return round(per_gram_24k * MAIN_KARAT / 24.0, 4), first.date(), last.date()


def books_start() -> date:
    """The first posted entry's day -- the opening of the replay."""
    return db.session.query(func.min(JournalEntry.date)).filter(JournalEntry.is_posted.is_(True)).scalar().date()

