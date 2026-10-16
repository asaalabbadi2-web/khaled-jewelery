"""The weight position: a sale's riyals turn back into gold, and that is the weight profit (ADR-048).

The owner, 16 Oct 2026: «بعت 10 جرام بـ6000 ... إذا ارتفع السعر قد أشتري 8 جرام
بها وبذلك أصبح خاسر 2 جرام» -- the open order is riyals, not grams; a cash
purchase of gold or a marked expense closes it, first in first out.
"""
import datetime as dt
import uuid

import pytest
from flask import g

from services.weight_position import (CUSTOMER, EXPENSE, EXPENSE_SIDE, OFFICE, REVENUE, REVENUE_SIDE, Closing,
                                      Events, Lot, Return, replay, split_layers, unrealized)

D = dt.datetime


def _sale(cash, grams, day, price=None, invoice_id=None):
    return Lot('بيع', D(2031, 3, day, 10), cash, grams, price, invoice_id)


# ── the owner's example ────────────────────────────────────────────────────

def test_sold_10_g_for_6000_the_price_unchanged_it_is_2_g():
    result = replay(Events(openings=[_sale(6000, 10, 1, price=500)],
                           closings=[Closing(D(2031, 3, 2), CUSTOMER, 6000, 12)]))   # 6,000 at 500
    assert result.by_kind[CUSTOMER]['result'] == pytest.approx(2.0)
    assert result.open_lots == []


def test_the_price_rose_to_750_the_6000_buy_8_g_and_it_is_a_2_g_loss():
    result = replay(Events(openings=[_sale(6000, 10, 1, price=500)],
                           closings=[Closing(D(2031, 3, 2), CUSTOMER, 6000, 8)]))    # 6,000 at 750
    assert result.by_kind[CUSTOMER]['result'] == pytest.approx(-2.0)


def test_while_it_waits_it_is_valued_at_the_price_it_will_buy_at():
    result = replay(Events(openings=[_sale(6000, 10, 1, price=500)]))
    [lot] = result.open_lots
    assert unrealized(lot.cash_open, lot.grams_open, 500) == pytest.approx(2.0)
    assert unrealized(lot.cash_open, lot.grams_open, 750) == pytest.approx(-2.0)


# ── what opens and what closes ─────────────────────────────────────────────

def test_an_expense_closes_its_share_with_no_grams_bought():
    result = replay(Events(openings=[_sale(6000, 10, 1)],
                           closings=[Closing(D(2031, 3, 2), EXPENSE, 600),
                                     Closing(D(2031, 3, 3), CUSTOMER, 5400, 10.8)]))   # the rest at 500
    assert result.by_kind[EXPENSE]['result'] == pytest.approx(-1.0)
    assert result.by_kind[CUSTOMER]['result'] == pytest.approx(1.8)
    # As gram profit counts it: 6,000/500 - 10 = +2, less 600/500 = 1.2 -> +0.8.
    assert sum(b['result'] for b in result.by_kind.values()) == pytest.approx(0.8)


def test_a_revenue_opens_riyals_with_no_grams_sold():
    result = replay(Events(openings=[Lot('إيرادات', D(2031, 3, 1), 500, 0.0)],
                           closings=[Closing(D(2031, 3, 2), CUSTOMER, 500, 1.0)]))
    assert result.by_kind[CUSTOMER]['result'] == pytest.approx(1.0)


def test_first_in_first_out_by_the_riyal():
    first, second = _sale(5000, 10, 1), _sale(6000, 10, 2)
    result = replay(Events(openings=[first, second], closings=[Closing(D(2031, 3, 3), OFFICE, 5500, 11)]))
    assert first.cash_open == pytest.approx(0.0)
    assert second.cash_open == pytest.approx(5500.0)
    assert second.grams_open == pytest.approx(10 * 5500 / 6000)
    assert result.by_kind[OFFICE]['grams_out'] == pytest.approx(10 + 10 * 500 / 6000)


def test_a_return_takes_its_riyals_and_grams_off_its_sale():
    sale = _sale(6000, 10, 1, invoice_id=7)
    result = replay(Events(openings=[sale], returns=[Return(D(2031, 3, 2), 7, 3000, 5)]))
    assert (sale.cash_open, sale.grams_open) == (pytest.approx(3000), pytest.approx(5))
    assert not result.anomalies


def test_riyals_spent_with_no_sale_open_are_set_aside_not_counted():
    result = replay(Events(closings=[Closing(D(2031, 3, 1), CUSTOMER, 1000, 2)]))
    assert result.by_kind == {}
    assert [(c.kind, c.cash) for c in result.unmatched] == [(CUSTOMER, 1000)]


def test_a_weight_line_is_a_result_at_once():
    result = replay(Events(direct=[(D(2031, 3, 5), -0.5, EXPENSE_SIDE)]))
    assert result.by_kind['direct']['result'] == pytest.approx(-0.5)


# ── the five layers ────────────────────────────────────────────────────────

def _layered(price=500.0):
    """Sold 10 g for 6,000; a revenue of 500; an expense of 600; a weight
    loss of 0.3 g; and everything left turned into gold at one *price*."""
    events = Events(openings=[_sale(6000, 10, 1), Lot('إيرادات', D(2031, 3, 1, 23), 500, 0.0, kind=REVENUE)],
                    closings=[Closing(D(2031, 3, 2), EXPENSE, 600),
                              Closing(D(2031, 3, 3), CUSTOMER, 5900, 5900 / price)],
                    direct=[(D(2031, 3, 4), -0.3, EXPENSE_SIDE), (D(2031, 3, 4), 0.1, REVENUE_SIDE)])
    result = replay(events)
    return result, split_layers(result.slices, result.direct)


def test_the_layers_add_up_to_the_whole():
    result, layers = _layered()
    whole = sum(s.result for s in result.slices) + sum(d[1] for d in result.direct)
    assert sum(layers.values()) == pytest.approx(whole)
    assert layers['expense_direct'] == pytest.approx(-0.3)
    assert layers['revenue_direct'] == pytest.approx(0.1)
    assert layers['expense_cash'] == pytest.approx(-1.0)          # 600 of the 6,000 for 10 g


def test_all_turned_into_gold_at_one_price_five_layers_equal_the_old_four():
    """The old report: (sales + revenues - expenses) / the average buy price
    - grams sold, plus the weight lines. With nothing left open and one price,
    the five layers give the same, to the gram."""
    for price in (450.0, 500.0, 600.0):
        result, layers = _layered(price)
        assert not result.open_lots
        old_four = (6000 + 500 - 600) / price - 10 + 0.1 - 0.3
        assert sum(layers.values()) == pytest.approx(old_four), price


# ── from the books ─────────────────────────────────────────────────────────

from tests.retraction_world import world  # noqa: E402,F401 (fixture)


@pytest.fixture(scope='module')
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(request, db_fence):
    yield


def _post(auth_headers, body):
    from app import app as flask_app
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    return resp.get_json()['id']


def test_the_books_open_a_sale_close_a_scrap_purchase_and_a_marked_expense(app, auth_headers, world):
    """In a period of its own (March 2031): a sale through the real route opens
    its price and grams; a customer's scrap bought closes with its grams; a
    marked expense's line closes with none; a supplier's purchase is not read."""
    from models import Account, JournalEntry, JournalEntryLine, db
    from services.weight_position import collect_events
    when = '2031-03-10T10:00:00'
    sale_id = _post(auth_headers, {
        'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'gold_type': 'new',
        'employee_id': world['holder'].id, 'date': when, 'total': 1000.0, 'total_weight': 2.0, 'total_tax': 0.0,
        'amount_paid': 1000.0, 'payments': [{'payment_method_id': world['pm'].id, 'amount': 1000.0}],
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                   'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]})
    buy_id = _post(auth_headers, {
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': '2031-03-11T10:00:00', 'total': 100.0, 'total_weight': 1.0, 'total_cost': 100.0,
        'total_tax': 0.0, 'amount_paid': 100.0, 'payments': [{'payment_method_id': world['pm'].id, 'amount': 100.0}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': 1.0, 'standing_weight': 1.0, 'stones_weight': 0.0,
                   'price': 100.0, 'net': 100.0, 'quantity': 1}]})   # below the live price: posted, not held
    expense = Account(account_number=f'59{uuid.uuid4().int % 10**6:06d}', name='مصروف موسوم', type='Expense',
                      include_in_gram_profit=True)
    db.session.add(expense)
    db.session.flush()
    from accounting.chart_tree import EXPENSES_ROOT, role_account_id
    expense.parent_id = role_account_id(EXPENSES_ROOT)
    je = JournalEntry(entry_number=f'JE-WP-{uuid.uuid4().hex[:6]}', date=dt.datetime(2031, 3, 12, 10),
                      description='مصروف', entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=expense.id, cash_debit=50.0),
                        JournalEntryLine(journal_entry_id=je.id, account_id=world['pm'].default_safe_box.account_id
                                         if getattr(world['pm'], 'default_safe_box', None) else expense.id,
                                         cash_credit=50.0)])
    db.session.flush()

    events = collect_events(D(2031, 3, 1), D(2031, 3, 31, 23, 59))
    assert [(l.invoice_id, round(l.cash, 2), round(l.grams, 3)) for l in events.openings if l.invoice_id] == \
        [(sale_id, 1000.0, 2.0)]
    closings = [(c.kind, round(c.cash, 2), round(c.grams, 3)) for c in events.closings]
    assert (CUSTOMER, 100.0, 1.0) in closings
    assert (EXPENSE, 50.0, 0.0) in closings
    assert buy_id


def test_an_expense_spends_what_was_sold_and_a_purchase_turns_a_revenue_into_gold():
    """A revenue of 500 opened before the sale's riyals are spent: the expense
    still spends the sale's riyals (④ = the grams sold it spent), the purchase
    the revenue's (② = what the revenue bought) -- and the whole is the same
    whichever way the riyals are paired."""
    events = Events(openings=[Lot('إيرادات', D(2031, 3, 1, 9), 500, 0.0, kind=REVENUE), _sale(6000, 10, 1)],
                    closings=[Closing(D(2031, 3, 2), EXPENSE, 600), Closing(D(2031, 3, 3), CUSTOMER, 1000, 2)])
    result = replay(events)
    layers = split_layers(result.slices, result.direct)
    assert layers['expense_cash'] == pytest.approx(-1.0)                   # 600 of 6,000 for 10 g
    assert layers['revenue_converted'] == pytest.approx(1.0)               # 500 at 500
    assert layers['trading'] == pytest.approx(1.0 - 10 * 500 / 6000)       # the other 500 of the sale
    open_cash = sum(l.cash_open for l in result.open_lots)
    open_grams = sum(l.grams_open for l in result.open_lots)
    whole = sum(layers.values()) + unrealized(open_cash, open_grams, 500)
    assert whole == pytest.approx((6000 + 500 - 600) / 500 - 10)


# ── the routes ─────────────────────────────────────────────────────────────

def _headers(role):
    from auth_decorators import generate_token
    from models import AppUser, db
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _get(path, headers):
    from app import app as flask_app
    g.pop('current_user', None)
    return flask_app.test_client().get(path, headers=headers)


def test_the_position_and_the_performance_are_served_to_who_reads_the_profits(app):
    position = _get('/api/reports/weight-position?as_of=2031-03-31', _headers('accountant'))
    assert position.status_code == 200, position.get_data(as_text=True)[:300]
    body = position.get_json()
    for key in ('open_cash', 'purchase_price', 'unrealized', 'grams_per_price_percent', 'lots',
                'recent_closings', 'where_the_riyals_are'):
        assert key in body, key
    perf = _get('/api/reports/weight-performance?start_date=2031-03-01&end_date=2031-03-31', _headers('manager'))
    assert perf.status_code == 200, perf.get_data(as_text=True)[:300]
    period = perf.get_json()['period']
    assert set(period['layers']) == {'trading', 'revenue_converted', 'revenue_direct', 'expense_direct',
                                     'expense_cash', 'price_effect'}
    assert period['weight_profit'] == pytest.approx(sum(period['layers'].values()), abs=0.01)


def test_not_to_a_storekeeper(app):
    assert _get('/api/reports/weight-position', _headers('storekeeper')).status_code == 403
    assert _get('/api/reports/weight-performance', _headers('storekeeper')).status_code == 403


def test_a_bad_date_is_refused_by_name(app):
    resp = _get('/api/reports/weight-performance?start_date=2031-04-01&end_date=2031-03-01', _headers('manager'))
    assert resp.status_code == 400 and resp.get_json()['error'] == 'invalid_range'


def test_gram_profit_is_the_engine_s_five_layers(app):
    resp = _get('/api/reports/gram_profit?start_date=2031-03-01&end_date=2031-03-31', _headers('manager'))
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert 'price_effect_weight' in body and body['unavailable_reason'] is None
    whole = (body['trading_profit_weight'] + body['extra_revenue_cash_as_weight'] + body['extra_revenue_weight']
             - body['expense_weight_direct'] - body['expense_cash_as_weight'] + body['price_effect_weight'])
    assert body['net_profit_weight'] == pytest.approx(whole, abs=0.01)


def test_a_day_with_no_purchase_moves_no_price(app, auth_headers, world):
    """The open riyals are valued at the last purchase days, not calendar days:
    a quiet day showed -10 g only because an old day left a calendar window
    (16 Oct 2026)."""
    from services.weight_position import purchase_price
    for day in ('2031-03-09', '2031-03-11'):
        _post(auth_headers, {
            'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
            'transaction_type': 'buy', 'employee_id': world['holder'].id,
            'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
            'date': f'{day}T10:00:00', 'total': 100.0, 'total_weight': 1.0, 'total_cost': 100.0, 'total_tax': 0.0,
            'amount_paid': 100.0, 'payments': [{'payment_method_id': world['pm'].id, 'amount': 100.0}],
            'items': [{'name': 'كسر', 'karat': 21, 'weight': 1.0, 'standing_weight': 1.0, 'stones_weight': 0.0,
                       'price': 100.0, 'net': 100.0, 'quantity': 1}]})
    after = purchase_price(dt.date(2031, 3, 12))
    weeks_later = purchase_price(dt.date(2031, 3, 30))
    assert after[0] == pytest.approx(100.0) and weeks_later[0] == pytest.approx(after[0])
