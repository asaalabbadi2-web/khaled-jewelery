"""The gold's cost by month, as the moving-average replay measures it (ADR-042, phase 1).

Reads the posted books and writes nothing. For each month: the gold bought and
what it cost, the worked and scrap gold sold and what it cost, the exchange
differences, and the revenue and gross profit beside the income statement's
of today (purchases-based); then each pool's closing weight, value and average,
against the books' weight.

    python tools/report/gold_cost_measure.py                       # the market average
    python tools/report/gold_cost_measure.py --opening-price 480   # entered by hand

The opening price (the owner, 11 Oct 2026): entered by hand -- the previous
year's average where there is one -- or else the market price's average over
the first 30 days of recorded prices. Run it on a restored copy.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--opening-price', type=float, default=None,
                    help='riyals per main-karat gram, entered by hand (default: the market average)')
    args = ap.parse_args(argv)

    from sqlalchemy import func
    from app import app
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    from services.gold_cost import books_start, ledger_weights, market_average_price, replay
    from services.income_accounts import income_account_groups

    with app.app_context():
        groups = income_account_groups()
        if args.opening_price is None:
            price, first, last = market_average_price(books_start())
            source = f'the market average, {first} to {last}'
        else:
            price, source = args.opening_price, 'entered by hand'
        result = replay(opening_price=price)

        def monthly(ids):
            month = func.to_char(JournalEntry.date, 'YYYY-MM')
            rows = (db.session.query(month, func.sum(JournalEntryLine.cash_credit - JournalEntryLine.cash_debit))
                    .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                    .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(ids or {-1}))
                    .group_by(month).all())
            return {k: float(v or 0) for k, v in rows}

        revenue, cost_today = monthly(groups['revenue']), {k: -v for k, v in monthly(groups['cost_of_sales']).items()}
        print(f'opening price: {price:,.2f} per main-karat gram ({source})')
        print('month   | bought g  | bought cost  | worked sold g | its cost     | scrap sold g | its cost  '
              '| exch. diff | revenue      | gross: today | gross: by cost')
        for k in sorted(result.months):
            m = result.months[k]
            cost = m.cost_of_worked_sold + m.cost_of_scrap_sold + m.exchange_difference
            print(f'{k} | {m.purchases_g:9.1f} | {m.purchases_value:12,.0f} | {m.sold_worked_g:13.1f} | '
                  f'{m.cost_of_worked_sold:12,.0f} | {m.sold_scrap_g:12.1f} | {m.cost_of_scrap_sold:9,.0f} | '
                  f'{m.exchange_difference:10,.0f} | {revenue.get(k, 0):12,.0f} | '
                  f'{revenue.get(k, 0) - cost_today.get(k, 0):12,.0f} | {revenue.get(k, 0) - cost:14,.0f}')
        books = ledger_weights()
        for name, pool in result.pools.items():
            print(f'{name}: {pool.weight:,.3f} g · {pool.value:,.2f} · average {pool.avg:,.2f} '
                  f'(the books: {books[name]:,.3f} g)')
        total = lambda f: sum(getattr(m, f) for m in result.months.values())
        print(f'gold charged to expenses: {-total("expense_g"):,.3f} g, {-total("expense_value"):,.2f}')
        print(f'gold with parties (a receivable, not a cost): {-total("receivables_g"):,.3f} g, '
              f'{-total("receivables_value"):,.2f}')
        print(f'purchases returned: {-total("purchase_returns_g"):,.3f} g, {-total("purchase_returns_value"):,.2f} '
              f'· gold gained: {total("other_income_g"):,.3f} g, {total("other_income_value"):,.2f}')
        print(f'for review -- gold paid out or adjusted, at the average: {len(result.others)} entries, '
              f'{sum(o["grams"] for o in result.others):,.1f} g')
        for o in result.others:
            print(f'  {o["date"]} {o["entry"]} {o["pool"]} {o["grams"]:,.3f} g  {o["description"]}')


if __name__ == '__main__':
    main()
