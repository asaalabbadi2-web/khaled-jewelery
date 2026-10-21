"""Gold bought for riyals enters its pool's stock at its price (ADR-042 phase 3, step 2).

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
the same stock. Each writer calls these after its entry's weight lines are
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
