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
  the rest     by the nature of the account the gold went to (the owner):
               an expense account -- an expense; a party's account -- a
               receivable; a sales return, a purchase return, gold gained;
               what fits none is listed for review

Below zero (the owner, 11 Oct 2026): a short pool is valued at its average when
it went short; gold bought while it is short covers the short first, at its
price, and the difference between the two goes to «فروق تكلفة تبادل الذهب».
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime

from sqlalchemy import func

from models import Invoice, JournalEntry, JournalEntryLine, OfficeReservation, db

KARATS = (18, 21, 22, 24)


def _main_karat() -> float:
    """The settings' main karat -- it was a constant 21 here (20 Oct 2026)."""
    from pricing.gold_price_service import get_main_karat
    return float(get_main_karat())

def _mapped_subtree(operation: str, role: str) -> set[int]:
    from accounting.chart_tree import subtree_ids
    from accounting.mappings import get_account_id_for_mapping
    account_id = get_account_id_for_mapping(operation, role)
    return subtree_ids(account_id) if account_id else set()


def _safes_of(pool: str) -> set[int]:
    """The weight accounts of the gold safes whose stock location is in *pool*
    (COST_POOL_OF_LOCATION) -- active or not: a balance is a balance."""
    from models import COST_POOL_OF_LOCATION, SafeBox
    locations = [loc for loc, p in COST_POOL_OF_LOCATION.items() if p == pool]
    return {int(a) for (a,) in db.session.query(SafeBox.account_id)
            .filter(SafeBox.safe_type == 'gold', SafeBox.stock_location.in_(locations)).all()}


# Which accounts are which pool. The pools' gold is its safes by their stock
# location (ADR-045; the owner, 21 Oct 2026 -- it was the tree under 1300's and
# 1310's weight twins, which left out the offices' deposits) and the pool's
# stock weight account itself; the gold owed to the worked-gold suppliers
# counts out of the scrap. The rest are roles (a
# policy: data, not law) -- a role's account or its linked weight twin, the
# subtree under it (CHART-002 release 5).
def pool_accounts() -> dict[str, set[int]]:
    from accounting.chart_tree import (
        ASSETS_ROOT, COST_OF_SALES_ROOT, CUSTOMER_RECEIVABLES_ROOT, EQUITY_ROOT, LIABILITIES_ROOT,
        OPERATING_EXPENSES_ROOT, REVENUE_ROOT, WORKED_GOLD_SUPPLIERS_ROOT, role_subtree_ids, subtree_ids, twin_id,
        twin_subtree_ids)
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE as DEFAULT, require_account

    def own(operation, role):
        return subtree_ids(require_account(operation, role))

    def own_twin(operation, role):
        # the pool's stock weight account itself: gold posted on it is the
        # pool's, in no safe (2026's office reservations staged there)
        twin_account = twin_id(require_account(operation, role))
        return {int(twin_account)} if twin_account else set()

    def twin(operation, role):
        twin_account = twin_id(require_account(operation, role))
        return subtree_ids(twin_account) if twin_account else set()

    return {
        'worked': _safes_of('worked') | own_twin(DEFAULT, 'gold_inventory_new'),
        'scrap': _safes_of('scrap') | own_twin(DEFAULT, 'gold_inventory_scrap') | twin_subtree_ids(WORKED_GOLD_SUPPLIERS_ROOT),
        # where each pool's value is: its financial stock account (1300, 1310)
        'worked_value': own(DEFAULT, 'gold_inventory_new'),
        'scrap_value': own(DEFAULT, 'gold_inventory_scrap'),
        # where a purchase covering a short writes its difference (phase 3) --
        # part of what the gold cost; unmapped before phase 3, then none
        'exchange_difference': _mapped_subtree(DEFAULT, 'gold_exchange_difference'),
        # a sale's cost, in riyals -- what tells a sale from a purchase undone
        'cost_of_sales': role_subtree_ids(COST_OF_SALES_ROOT) | _mapped_subtree(DEFAULT, 'gold_cost_of_sales'),
        # where a purchase's price is debited
        'purchase_cash': own('شراء من عميل', 'purchases_gold_scrap') | own(DEFAULT, 'gold_inventory_scrap'),
        'customers': twin_subtree_ids(CUSTOMER_RECEIVABLES_ROOT),
        'sales_twin': twin_subtree_ids(REVENUE_ROOT),                # early sales wrote these
        'weight_expense': twin_subtree_ids(OPERATING_EXPENSES_ROOT),  # operating expenses, by weight
        'weight_cost_of_sales': twin_subtree_ids(COST_OF_SALES_ROOT),  # purchases and their returns, by weight
        'sales_returns': twin('مرتجع بيع', 'sales_returns'),
        'party': twin_subtree_ids(ASSETS_ROOT) | twin_subtree_ids(LIABILITIES_ROOT),  # parties' weight accounts
        'equity': twin_subtree_ids(EQUITY_ROOT),
        'wage_cost': own('بيع', 'manufacturing_wage'),  # the making charge: a cost the average does not replace
    }

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

    def take_at(self, grams: float, value: float) -> None:
        """Grams out at *value* -- a purchase undone at its price."""
        self.weight -= grams
        self.value -= value
        self._settle()

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
    expense_g: float = 0.0          # gold charged to an expense account
    expense_value: float = 0.0
    receivables_g: float = 0.0      # gold handed to (-) or received back from (+) a party: a receivable
    receivables_value: float = 0.0
    purchase_returns_g: float = 0.0
    purchase_returns_value: float = 0.0
    other_income_g: float = 0.0     # gold gained -- casting and assay, a discount earned
    other_income_value: float = 0.0


@dataclass
class Replay:
    days: list = field(default_factory=list)       # (date, {pool: (weight, value, avg)})
    months: dict = field(default_factory=dict)     # 'YYYY-MM' -> Month
    others: list = field(default_factory=list)     # unclassified entries, for review
    pools: dict = field(default_factory=dict)


def _grams(line) -> float:
    main = _main_karat()
    return sum((float(getattr(line, f'debit_{k}k') or 0) - float(getattr(line, f'credit_{k}k') or 0)) * k / main
               for k in KARATS)


def replay(*, opening_price: float, since: date | None = None, until: date | None = None) -> Replay:
    """Replay every posted movement of the two pools, oldest first."""
    from accounting.balances import counted_line_filters
    pools = pool_accounts()
    worked, scrap = pools['worked'], pools['scrap']
    cash_accounts = pools['purchase_cash']
    exchange_accounts = pools['exchange_difference']
    cost_of_sales_cash = pools['cost_of_sales']
    customers, equity = pools['customers'], pools['equity']
    sales_twin = pools['sales_twin']
    # By the nature of the account the gold went to (the owner, 11 Oct 2026):
    expense_accounts = pools['weight_expense']
    cost_of_sales_weight = pools['weight_cost_of_sales']
    sales_returns = pools['sales_returns']
    receivable_accounts = pools['party'] - worked - scrap
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
        import re
        originals = JournalEntry.query.filter(JournalEntry.id.in_([t.reference_id for t in transfers])).all()
        # An entry that lost its link names its reservation in its description
        # (JE-2026-03240: «إرسال ذهب للحجز (RES-20260616175502-0017)»).
        codes = {o.id: m.group(0) for o in originals
                 if o.reference_id is None and (m := re.search(r'RES-\d+-\d+', o.description or ''))}
        by_id = {r.id: r for r in OfficeReservation.query.filter(
            OfficeReservation.id.in_({o.reference_id for o in originals if o.reference_id})).all()}
        by_code = {r.reservation_code: r for r in OfficeReservation.query.filter(
            OfficeReservation.reservation_code.in_(set(codes.values()))).all()} if codes else {}
        original_of = {o.id: o for o in originals}
        for t in transfers:
            o = original_of.get(t.reference_id)
            r = (by_id.get(o.reference_id) if o is not None and o.reference_id else by_code.get(codes.get(t.reference_id)))
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
        # Phase 3 writes a purchase on its pool's stock, its difference over a
        # short's average beside it: the price is both (services/gold_cost_postings).
        exchanged = sum(float(l.cash_debit or 0) - float(l.cash_credit or 0)
                        for l in lines if l.account_id in exchange_accounts)
        if cash_price > 0:
            cash_price += exchanged
        # A purchase undone (its return, its reversal): the price credited back
        # -- not a sale, which credits the stock its cost against a cost of sales.
        cash_refund = sum(float(l.cash_credit or 0) for l in lines if l.account_id in cash_accounts)
        if any(float(l.cash_debit or 0) > 0 for l in lines if l.account_id in cost_of_sales_cash):
            cash_refund = 0.0
        if cash_refund > 0:
            cash_refund -= exchanged

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
            elif grams < 0 and cash_refund > 0 and e.reference_type not in CORRECTION_TYPES:
                pool.take_at(-grams, cash_refund)
                m.purchases_g += grams
                m.purchases_value -= cash_refund
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
                # The rest, by the nature of the account the gold went to or came
                # from (the owner, 11 Oct 2026: «اعتمد على طبيعة الحساب المسجل
                # عليه الوزن»): an expense account -- an expense; a party's
                # account -- a receivable (an advance, a drawing, zakat charged to
                # a partner), not a cost; a sales return -- the sale undone; a
                # purchase account -- a purchase returned; a revenue account --
                # gold gained. All at the average.
                if grams > 0:
                    value = grams * pool.avg
                    pool.put(grams, value)
                else:
                    value = -pool.take(-grams)
                if accounts & expense_accounts:
                    m.expense_g += grams
                    m.expense_value += value
                elif accounts & sales_returns and grams > 0:
                    target = out.months.setdefault(corrected_month.get(e.id, e.date.strftime('%Y-%m')), Month())
                    if name == 'worked':
                        target.sold_worked_g -= grams
                        target.cost_of_worked_sold -= value
                    else:
                        target.sold_scrap_g -= grams
                        target.cost_of_scrap_sold -= value
                elif accounts & cost_of_sales_weight:
                    m.purchase_returns_g += grams
                    m.purchase_returns_value += value
                elif accounts & sales_twin and grams > 0:
                    m.other_income_g += grams
                    m.other_income_value += value
                elif accounts & receivable_accounts:
                    m.receivables_g += grams
                    m.receivables_value += value
                else:
                    m.other_g += grams
                    m.other_value += value
                    out.others.append({'entry': e.entry_number, 'date': day, 'pool': name, 'grams': round(grams, 3),
                                       'reference': f'{e.reference_type}:{e.reference_id}',
                                       'description': (e.description or '')[:80]})
    if current_day is not None:
        snapshot(current_day)
    return out


def _ledger_sums(ids: set[int], until: datetime | None, excluding_entry_id: int | None = None
                 ) -> tuple[float, float]:
    """The posted balance of *ids*: (main-karat grams, riyals), entries before
    *until*, without *excluding_entry_id* (the entry being written)."""
    from accounting.balances import counted_line_filters
    main = _main_karat()
    grams = sum((func.coalesce(func.sum(getattr(JournalEntryLine, f'debit_{k}k')), 0.0)
                 - func.coalesce(func.sum(getattr(JournalEntryLine, f'credit_{k}k')), 0.0)) * k / main
                for k in KARATS)
    riyals = (func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0)
              - func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0))
    query = (db.session.query(grams, riyals).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(ids or {-1})))
    if until is not None:
        query = query.filter(JournalEntry.date < until)
    if excluding_entry_id is not None:
        query = query.filter(JournalEntry.id != excluding_entry_id)
    g, r = query.one()
    return float(g or 0.0), float(r or 0.0)


@dataclass(frozen=True)
class PoolState:
    weight: float      # main-karat grams
    value: float       # riyals

    @property
    def average(self) -> float | None:
        """The value over the weight -- a short pool keeps its average (both
        below zero); None when the pool is empty: there is no average to take."""
        return self.value / self.weight if abs(self.weight) > EPS else None


def pool_state(name: str, *, until: datetime | None = None, excluding_entry_id: int | None = None) -> PoolState:
    """A pool as the ledger holds it (ADR-042 phase 3; the owner, 21 Oct 2026):
    its weight on its safes and its suppliers' gold, its value on its financial
    stock account -- the one reader of the average a posting takes. Before
    *until* when given, else all that is posted; without the entry being written."""
    if name not in ('worked', 'scrap'):
        raise ValueError(f'no such pool: {name}')
    pools = pool_accounts()
    weight, _ = _ledger_sums(pools[name], until, excluding_entry_id)
    _, value = _ledger_sums(pools[f'{name}_value'], until, excluding_entry_id)
    return PoolState(weight=weight, value=value)


def ledger_weights() -> dict:
    """Each pool's weight as the books say it -- the replay must end on it."""
    pools = pool_accounts()
    return {name: _ledger_sums(pools[name], None)[0] for name in ('scrap', 'worked')}


def gross_by_month(result: Replay) -> dict[str, dict]:
    """Each month's gross profit both ways, beside each other: today's (the
    income statement -- revenue less the cost-of-sales group, purchases charged
    as they are bought) and by cost (revenue less the gold's cost at the
    average and the making charge, which the average does not replace)."""
    from accounting.balances import counted_line_filters
    from services.income_accounts import income_account_groups

    def monthly(ids):
        month = func.to_char(JournalEntry.date, 'YYYY-MM')
        rows = (db.session.query(month, func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
                .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(ids or {-1}))
                .group_by(month).all())
        return {k: float(v or 0) for k, v in rows}

    groups = income_account_groups()
    revenue = {k: -v for k, v in monthly(groups['revenue']).items()}
    cost_today, wages = monthly(groups['cost_of_sales']), monthly(pool_accounts()['wage_cost'])
    out = {}
    for k in sorted(set(result.months) | set(revenue) | set(cost_today)):
        m = result.months.get(k, Month())
        gold_cost = m.cost_of_worked_sold + m.cost_of_scrap_sold + m.exchange_difference
        out[k] = {
            'revenue': revenue.get(k, 0.0),
            'cost_today': cost_today.get(k, 0.0),
            'gross_today': revenue.get(k, 0.0) - cost_today.get(k, 0.0),
            'gold_cost': gold_cost,
            'wages': wages.get(k, 0.0),
            'gross_by_cost': revenue.get(k, 0.0) - gold_cost - wages.get(k, 0.0),
        }
    return out


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
    return round(per_gram_24k * _main_karat() / 24.0, 4), first.date(), last.date()


def books_start() -> date:
    """The first posted entry's day -- the opening of the replay."""
    return db.session.query(func.min(JournalEntry.date)).filter(JournalEntry.is_posted.is_(True)).scalar().date()

