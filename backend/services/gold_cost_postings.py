"""The gold's value through the books: bought at its price, sold at its average (ADR-042 phase 3, steps 2-3).

The owner (21 Oct 2026): «اتفق مع توصياتك بجميع القرارات». From the day the
settings name (Settings.gold_cost_from -- the 2027 database's first day,
ADR-044), a gold purchase paid in riyals is no longer an expense on purchases
(512): its price is the value of the gold it brings, on its pool's financial
stock account (1310 the scrap, 1300 the worked) -- the cost leaves the stock
when the gold is sold, at the pool's average (step 3). Before that day, and
with no day set, nothing changes: 2026 posts as it always has.

The pool is the one the entry's gold enters (services/gold_cost.pool_accounts:
its safes by their stock location). A pool short -- owing a supplier more gold
than it holds -- is covered first, at the short's average; the difference
between the price and that average goes to «فروق تكلفة تبادل الذهب», seen,
not buried in the average (the replay's Pool.put, the same rule).

A purchase undone (a customer purchase's return) takes its price back out of
the same stock.

Sold (step 3), the gold leaves its pool's stock at the pool's average, onto
its cost of sales -- «تكلفة مبيعات الذهب» for the worked, «تكلفة الكسر
المباع» for the scrap: two margins, seen apart (the owner). A sale returned
brings its sale's cost back, in the share returned, onto the pool it enters --
the cost its sale posted, never the screen's. Each writer calls these after its entry's weight lines are
written; the replay (services/gold_cost.replay) reads what they write as it
computes it -- the nightly witness (step 7).
"""
from __future__ import annotations

from datetime import date, datetime

from models import JournalEntryLine, Settings, db

CENT = 0.005


class GoldCostRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def applies(on) -> bool:
    """Whether a document of *on* (a date or datetime) takes the rule."""
    settings = Settings.query.first()
    start = getattr(settings, 'gold_cost_from', None)
    if start is None or on is None:
        return False
    day = on.date() if isinstance(on, datetime) else on
    return day >= start


def _pool_grams(journal_entry_id: int) -> dict[str, float]:
    from services.gold_cost import _grams, pool_accounts
    db.session.flush()
    pools = pool_accounts()
    lines = JournalEntryLine.query.filter_by(journal_entry_id=journal_entry_id, is_deleted=False).all()
    return {name: sum(_grams(l) for l in lines if l.account_id in pools[name]) for name in ('worked', 'scrap')}


def _the_pool(journal_entry_id: int, sign: int) -> tuple[str, float]:
    """The one pool the entry's gold enters (sign +1) or leaves (-1), and its grams."""
    grams = _pool_grams(journal_entry_id)
    moving = {n: g * sign for n, g in grams.items() if abs(g) > CENT}
    if len(moving) != 1 or next(iter(moving.values())) <= 0:
        raise GoldCostRefused('gold_cost_pool_unclear',
                              'لا يُعرف مخزن الذهب: يجب أن يدخل ذهب القيد أو يخرج من خزائن مخزن واحد لها نوع '
                              '(كسر، عهدة، وديعة، معروض) — يُضبط نوع الخزينة في شاشة الخزائن')
    (name, g), = moving.items()
    return name, g


def _require(role: str) -> int:
    """A role's account, or the posting refused saying where it is set."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, AccountNotMapped, require_account
    try:
        return require_account(DEFAULT_MAPPING_OPERATION_TYPE, role)
    except AccountNotMapped as exc:
        raise GoldCostRefused('account_not_mapped', str(exc)) from exc


def _value_account(name: str) -> int:
    return _require('gold_inventory_new' if name == 'worked' else 'gold_inventory_scrap')


def _line(journal_entry_id: int, account_id: int, amount: float, description: str):
    from dual_system_helpers import create_dual_journal_entry
    if abs(amount) < CENT:
        return
    create_dual_journal_entry(journal_entry_id=journal_entry_id, account_id=account_id,
                              **({'cash_debit': round(amount, 2)} if amount > 0 else {'cash_credit': round(-amount, 2)}),
                              apply_golden_rule=False, description=description)


def bought_into(journal_entry_id: int, price: float, *, description: str) -> dict:
    """The entry's gold, bought for *price*, into its pool's stock: debit the
    pool's value; a short covered first at its average, the difference to the
    exchange-difference role. Returns what was written."""
    from services.gold_cost import pool_state
    name, grams = _the_pool(journal_entry_id, +1)
    value_account = _value_account(name)
    exchange_account = _require('gold_exchange_difference')
    price = round(float(price or 0.0), 2)
    before = pool_state(name, excluding_entry_id=journal_entry_id)
    difference = 0.0
    if before.weight < -CENT:
        if before.average is None or before.average <= 0:
            raise GoldCostRefused('gold_cost_short_without_value',
                                  f'مخزن {"الكسر" if name == "scrap" else "المشغول"} ناقص {-before.weight:.3f} غ '
                                  'بلا قيمة في الدفاتر: لا متوسط يُغطّى به النقص — راجع قيد الافتتاح')
        covered = min(grams, -before.weight)
        difference = round(covered * (price / grams - before.average), 2)
    _line(journal_entry_id, value_account, price - difference, f'{description} — إلى المخزون')
    _line(journal_entry_id, exchange_account, difference, f'{description} — فرق تغطية النقص')
    return {'pool': name, 'grams': grams, 'value': round(price - difference, 2), 'difference': difference}


def returned_out(journal_entry_id: int, price: float, *, description: str) -> dict:
    """The entry's gold, a purchase undone, out of its pool's stock at *price*:
    credit the pool's value. Returns what was written."""
    name, grams = _the_pool(journal_entry_id, -1)
    price = round(float(price or 0.0), 2)
    _line(journal_entry_id, _value_account(name), -price, f'{description} — من المخزون')
    return {'pool': name, 'grams': grams, 'value': price}


COST_ROLE = {'worked': 'gold_cost_of_sales', 'scrap': 'scrap_cost_of_sales'}


def sold_out(journal_entry_id: int, *, description: str) -> dict:
    """The entry's gold, sold, out of its pool's stock at the pool's average:
    debit its cost of sales, credit the stock. Returns what was written."""
    from services.gold_cost import pool_state
    name, grams = _the_pool(journal_entry_id, -1)
    before = pool_state(name, excluding_entry_id=journal_entry_id)
    if before.average is None or before.average <= 0:
        raise GoldCostRefused('gold_cost_no_average',
                              f'مخزن {"الكسر" if name == "scrap" else "المشغول"} بلا متوسط '
                              f'({before.weight:.3f} غ بقيمة {before.value:.2f}): لا تكلفة يُباع بها — راجع قيد الافتتاح')
    cost = round(grams * before.average, 2)
    cost_account = _require(COST_ROLE[name])
    _line(journal_entry_id, cost_account, cost, f'{description} — تكلفة الذهب المباع')
    _line(journal_entry_id, _value_account(name), -cost, f'{description} — من المخزون')
    return {'pool': name, 'grams': grams, 'cost': cost, 'average': before.average}


def posted_sale_cost(invoice) -> dict[int, float]:
    """What a sale's entries posted as the gold's cost, by cost account -- its
    cost of sales, as written (none for a sale before the rule)."""
    from models import JournalEntry
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    accounts = {a for a in (get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, r) for r in COST_ROLE.values()) if a}
    if not accounts:
        return {}
    entry_ids = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice.id,
                                                            is_deleted=False).all()]
    cost: dict[int, float] = {}
    for l in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entry_ids or [-1]),
                                           JournalEntryLine.account_id.in_(accounts),
                                           JournalEntryLine.is_deleted.is_(False)).all():
        cost[l.account_id] = cost.get(l.account_id, 0.0) + float(l.cash_debit or 0) - float(l.cash_credit or 0)
    return {a: round(v, 2) for a, v in cost.items() if abs(v) >= CENT}


def sale_returned_in(journal_entry_id: int, ret, original, *, description: str) -> dict:
    """The entry's gold, a sale returned, back into the pool it enters at its
    sale's posted cost, in the share returned: debit the stock, credit the
    cost of sales it was charged to. Returns what was written."""
    from points.engine import returned_share
    name, grams = _the_pool(journal_entry_id, +1)
    cost = posted_sale_cost(original) if original is not None else {}
    if not cost:
        raise GoldCostRefused('gold_cost_return_of_uncosted_sale',
                              'البيع الأصلي لم تُكتب له تكلفة ذهب (قبل يوم التكلفة بالمتوسط، أو من سنة مقفلة): '
                              'لا يُرجَع بهذا المستند')
    share = returned_share(ret, original)
    back = {a: round(v * share, 2) for a, v in cost.items()}
    for account_id, amount in back.items():
        _line(journal_entry_id, account_id, -amount, f'{description} — عكس تكلفة الذهب المباع')
    total = round(sum(back.values()), 2)
    _line(journal_entry_id, _value_account(name), total, f'{description} — إلى المخزون')
    return {'pool': name, 'grams': grams, 'cost': total, 'share': share}


def _riyal_account(account_id: int) -> int:
    """A weight account's riyal side: itself when it carries riyals, else the
    financial account it is the twin of -- or the posting refused, naming it."""
    from models import Account
    account = db.session.get(Account, account_id)
    if account is not None and (account.transaction_type or 'both') in ('cash', 'both'):
        return account.id
    financial = Account.query.filter_by(memo_account_id=account_id).first()
    if financial is None:
        raise GoldCostRefused('gold_cost_no_riyal_account',
                              f'الحساب الوزني «{getattr(account, "name", account_id)}» بلا حساب مالي مقابل '
                              'تُقيَّد عليه قيمة ذهبه — يُربط له حساب مالي في شجرة الحسابات')
    return financial.id


def value_the_gold(journal_entry_id: int, *, description: str) -> dict:
    """The value of the gold an entry moves that no writer valued (step 4): a
    voucher's, a supplier purchase's, a count's, a melting's or a renewal's.

    - between the pools: at the average of the pool it leaves -- debit the
      stock it enters, credit the one it leaves; entering a short pool, the
      short is covered first and the difference said (the replay's rule);
    - out to an expense, or in from a revenue (a melting's stones, a
      renewal's): at its pool's average, on the expense's or revenue's riyal
      account;
    - out to a party (an advance, a drawing) at its pool's average, onto
      «ذهب لدى الأطراف»; back from a party at the value it left with -- the
      party's own average there (step 5; the owner's decision 7, 22 Oct 2026).
    Any other account is refused, so the average is never moved unseen. An
    entry that already writes value on a pool's stock was valued by its
    writer: left as it is. Returns what was written."""
    from services.gold_cost import Pool, _grams, pool_accounts, pool_state
    db.session.flush()
    pools = pool_accounts()
    lines = JournalEntryLine.query.filter_by(journal_entry_id=journal_entry_id, is_deleted=False).all()
    value_ids = pools['worked_value'] | pools['scrap_value']
    if any(abs(float(l.cash_debit or 0)) + abs(float(l.cash_credit or 0)) > CENT
           for l in lines if l.account_id in value_ids):
        return {}
    grams = {n: sum(_grams(l) for l in lines if l.account_id in pools[n]) for n in ('worked', 'scrap')}
    if all(abs(g) < CENT for g in grams.values()):
        return {}
    held = {}
    for n in ('worked', 'scrap'):
        state = pool_state(n, excluding_entry_id=journal_entry_id)
        held[n] = Pool(weight=state.weight, value=state.value, last_avg=state.average or 0.0)
    label = {'worked': 'المشغول', 'scrap': 'الكسر'}

    def need_average(n):
        if held[n].avg is None or held[n].avg <= 0:
            raise GoldCostRefused('gold_cost_no_average', f'مخزن {label[n]} بلا متوسط ({held[n].weight:.3f} غ '
                                                          f'بقيمة {held[n].value:.2f}): لا قيمة ينتقل بها الذهب')

    out = {'transfer': None, 'rest': []}
    rest = dict(grams)
    if grams['worked'] * grams['scrap'] < 0:
        src, dst = ('scrap', 'worked') if grams['worked'] > 0 else ('worked', 'scrap')
        moved = min(abs(grams['worked']), abs(grams['scrap']))
        need_average(src)
        if held[dst].weight < -CENT:
            need_average(dst)
        value = round(held[src].take(moved), 2)
        difference = round(held[dst].put(moved, value), 2)
        _line(journal_entry_id, _value_account(src), -value, f'{description} — من {label[src]}')
        _line(journal_entry_id, _value_account(dst), value - difference, f'{description} — إلى {label[dst]}')
        if abs(difference) >= CENT:
            _line(journal_entry_id, _require('gold_exchange_difference'), difference, f'{description} — فرق تغطية النقص')
        rest = {k: v - (moved if v > 0 else -moved) for k, v in grams.items()}
        out['transfer'] = {'from': src, 'to': dst, 'grams': moved, 'value': value, 'difference': difference}

    pool_ids = pools['worked'] | pools['scrap']
    party_ids = pools['party'] - pool_ids
    for n, g in rest.items():
        if abs(g) < CENT:
            continue
        counters = [(l, _grams(l)) for l in lines if l.account_id not in pool_ids and _grams(l) * g < -CENT ** 2]
        kinds = {l.account_id: ('expense' if l.account_id in pools['weight_expense']
                                else 'revenue' if l.account_id in pools['sales_twin']
                                else 'party' if l.account_id in party_ids else None) for l, _ in counters}
        # an expense either way (a write-off, or one undone); a revenue only in
        # (gold gained); a party either way (an advance, and its return)
        if not counters or None in kinds.values() or (g < 0 and 'revenue' in kinds.values()):
            raise GoldCostRefused('gold_cost_counter_not_built',
                                  f'ذهب {"يخرج من" if g < 0 else "يدخل"} مخزن {label[n]} '
                                  f'{"إلى" if g < 0 else "من"} حساب ليس مصروفًا ولا إيرادًا ولا طرفًا: '
                                  'لا تُعرف قيمته (ADR-042 المرحلة 3)')
        if g < 0 or held[n].weight < -CENT or set(kinds.values()) - {'party'}:
            need_average(n)
        weights = sum(abs(cg) for _, cg in counters)
        parts, total = [], 0.0
        for l, cg in counters:
            share = abs(g) * abs(cg) / weights
            if kinds[l.account_id] == 'party' and g > 0:
                held_grams, held_value = party_state(l.account_id, excluding_entry_id=journal_entry_id)
                if held_grams <= CENT or held_value <= 0:
                    raise GoldCostRefused('gold_cost_party_has_no_valued_gold',
                                          'ذهب يعود من طرف لم يخرج إليه ذهب مقيَّم: لا قيمة خرج بها يعود بها — '
                                          'يُسجَّل شراءً أو إيرادًا بمستنده')
                v = round(share * held_value / held_grams, 2)
                riyal = _require('gold_with_parties')
            else:
                v = round(share * held[n].avg, 2)
                riyal = _require('gold_with_parties') if kinds[l.account_id] == 'party' else _riyal_account(l.account_id)
            total += v
            _line(journal_entry_id, riyal, v if g < 0 else -v, f'{description} — قيمة الذهب')
            parts.append({'account_id': riyal, 'value': v, 'kind': kinds[l.account_id]})
        total = round(total, 2)
        difference = 0.0
        if g < 0:
            held[n].take(abs(g))
        else:
            difference = round(held[n].put(abs(g), total), 2)
        _line(journal_entry_id, _value_account(n), -total if g < 0 else total - difference,
              f'{description} — {"من" if g < 0 else "إلى"} {label[n]}')
        if abs(difference) >= CENT:
            _line(journal_entry_id, _require('gold_exchange_difference'), difference, f'{description} — فرق تغطية النقص')
        out['rest'].append({'pool': n, 'grams': g, 'value': total, 'difference': difference, 'counters': parts})
    return out


def party_state(weight_account_id: int, *, excluding_entry_id: int | None = None) -> tuple[float, float]:
    """The valued gold a party holds, from the ledger: (main-karat grams, riyals).
    Each posted entry that moves the party's gold and writes «ذهب لدى الأطراف»
    gives the party that value in the share of its grams among the entry's
    parties -- the share value_the_gold writes it in. Its average is what the
    gold comes back at (the owner's decision 7, 22 Oct 2026)."""
    from accounting.balances import counted_line_filters
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from models import JournalEntry
    from services.gold_cost import _grams, pool_accounts
    with_parties = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_with_parties')
    if not with_parties:
        return 0.0, 0.0
    pools = pool_accounts()
    party_ids = pools['party'] - pools['worked'] - pools['scrap']
    entries = (db.session.query(JournalEntryLine.journal_entry_id)
               .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
               .filter(*counted_line_filters(), JournalEntryLine.account_id == weight_account_id))
    if excluding_entry_id is not None:
        entries = entries.filter(JournalEntry.id != excluding_entry_id)
    ids = {r[0] for r in entries.distinct().all()}
    by_entry: dict[int, list] = {}
    for l in JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(ids or {-1}),
                                           JournalEntryLine.is_deleted.is_(False)).all():
        by_entry.setdefault(l.journal_entry_id, []).append(l)
    grams = value = 0.0
    for lines in by_entry.values():
        mine = sum(_grams(l) for l in lines if l.account_id == weight_account_id)
        written = sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in lines if l.account_id == with_parties)
        if abs(mine) < CENT or abs(written) < CENT:
            continue
        side = sum(_grams(l) for l in lines if l.account_id in party_ids and _grams(l) * mine > 0)
        grams += mine
        value += written * mine / side if side else written
    return round(grams, 6), round(value, 2)
