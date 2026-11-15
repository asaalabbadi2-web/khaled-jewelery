"""The net position: what the shop has, less what it owes -- for the dashboard's head (the owner, 15 Nov 2026).

«صافي المركز المالي» was the cash and the gold, nothing owed taken off:
11,088,017 on the 14 Nov copy, a gross called net. The balance sheet's own
assets less liabilities could not stand in for it yet -- its riyals carry
5.43M on the stock and 6.42M on the suppliers beside their grams, and
634,899 riyals sit on weight accounts. So the owner's choice («اودع وابني»):
each side by the reader the dashboard already trusts, nothing summed here
that a card does not say.

  has   the liquidity -- the safes, the banks, and what is on its way net
        of its commissions (the liquidity card's reading) -- the gold in
        the gold safes, and what the customers and the suppliers owe us,
        riyals and grams (the positions)
  owes  what we owe the customers and the suppliers, riyals and grams; the
        salaries owed; the VAT owed; each period expense's months accrued
        and unpaid -- owed now, not its months to come (the upcoming)

The grams at the closing office's price of the main karat, from the last
price saved -- said with its time. A part not read leaves the net not read.
Nothing here writes.
"""
from __future__ import annotations

from datetime import datetime


def compose(*, cash: float, transit: float, gold_grams: float, price: float, positions: dict,
            upcoming: dict) -> dict:
    """The net from its parts -- pure. *gold_grams* and the positions' grams in
    the main karat; *price* a gram of it."""
    customers, suppliers = positions['customers'], positions['suppliers']
    owed_to_us_cash = customers['owe_us_cash'] + suppliers['owe_us_cash']
    owed_to_us_gold = customers['owe_us_gold'] + suppliers['owe_us_gold']
    we_owe_cash = customers['we_owe_cash'] + suppliers['we_owe_cash']
    we_owe_gold = customers['we_owe_gold'] + suppliers['we_owe_gold']
    accrued = sum(e['owed_now'] for e in upcoming['period_expenses'])
    salaries, vat = upcoming['salaries']['amount'], upcoming['vat']

    has = cash + transit + (gold_grams + owed_to_us_gold) * price + owed_to_us_cash
    owes = we_owe_cash + we_owe_gold * price + salaries + vat + accrued
    return {
        'net': round(has - owes, 2),
        'has': round(has, 2),
        'owes': round(owes, 2),
        'parts': {
            'cash': round(cash, 2), 'transit': round(transit, 2),
            'gold_grams': round(gold_grams, 3), 'gold_value': round(gold_grams * price, 2),
            'owed_to_us_cash': round(owed_to_us_cash, 2), 'owed_to_us_gold': round(owed_to_us_gold, 3),
            'we_owe_cash': round(we_owe_cash, 2), 'we_owe_gold': round(we_owe_gold, 3),
            'salaries': round(salaries, 2), 'vat': round(vat, 2), 'period_expenses': round(accrued, 2),
        },
    }


def net_position(*, positions: dict | None, clearing: dict | None, upcoming: dict | None) -> dict:
    """The net, by the readers: the safes (the dashboard's), the last price
    saved, and the standing's own positions, clearing and upcoming. Raises when
    a part is not read -- the standing says the section null."""
    from models import GoldPrice, SafeBox
    from pricing.karat_service import get_main_karat
    from pricing.office_price import row_gram_price
    from services.live_balances import safe_box_balances_bulk

    if positions is None or clearing is None or upcoming is None:
        raise ValueError('a part of the net position was not read')
    if upcoming['suppliers']['cash'] is None or upcoming['vat'] is None:
        raise ValueError('the upcoming payments were not read whole')
    main = int(get_main_karat())
    latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    price = row_gram_price(latest, main) if latest is not None and latest.price else None
    if not price:
        raise ValueError('no gold price saved')
    safes = SafeBox.query.filter(SafeBox.is_active.is_(True)).all()
    balances = safe_box_balances_bulk(safes, main_karat=main)
    cash = sum(float((balances.get(s.id) or {}).get('cash') or 0.0) for s in safes if s.safe_type in ('cash', 'bank'))
    gold = sum(float(((balances.get(s.id) or {}).get('weight') or {}).get('total') or 0.0)
               for s in safes if s.safe_type == 'gold')
    out = compose(cash=cash, transit=float(clearing.get('total_net') or 0.0), gold_grams=gold, price=price,
                  positions=positions, upcoming=upcoming)
    out.update({'main_karat': main, 'price': round(price, 2),
                'price_at': latest.date.isoformat() if isinstance(latest.date, datetime) else None})
    return out
