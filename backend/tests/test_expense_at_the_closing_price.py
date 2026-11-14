"""A marked cash expense costs its riyals at the closing price of its day (ADR-048, the owner 14 Nov 2026).

«نحن نقوم بتسكير النقد على سعر الشراء المكاتب وليس على المبيعات»: the shop
turns its cash into gold at the offices' price, so riyals spent are the
grams they would have bought that day -- not the grams of the sale whose
riyals they were, which carry its wages. The laws:
  - ④ is the expense's riyals over the price of the day they left; a
    prepaid piece's day is its payment's, not the month that draws it;
  - what those riyals were worth over the grams sold for them is the sale's,
    in ① -- a revenue's, in ②;
  - the whole does not move: only the layers read differently;
  - a day before any office price takes the first supplier's purchase on or
    after it («سعر اول فاتورة شراء بعد هذا التاريخ»): its gold over its
    grams in the main karat, wages and tax aside; neither -- the grams sold,
    as before.

Run:
    python -m pytest tests/test_expense_at_the_closing_price.py -v
"""
import datetime as dt

import pytest

from services.weight_position import (CUSTOMER, EXPENSE, EXPENSE_SIDE, REVENUE, REVENUE_SIDE, Closing, Events,
                                      Lot, Slice, replay, split_layers)

D = dt.datetime


def _priced(table):
    def price_on(day):
        return (table.get(day, 0.0), 'سعر التسكير' if table.get(day) else 'لا سعر')
    return price_on


def _sale(cash, grams, day):
    return Lot('بيع', D(2031, 3, day, 10), cash, grams, None, 1000 + day)


def test_the_owners_rule_the_expense_at_the_day_price_and_the_sale_keeps_its_margin():
    # sold 10 g for 6,000 (600 a gram with its wages); 600 spent on a day the office's price is 500
    result = replay(Events(openings=[_sale(6000, 10, 1)], closings=[Closing(D(2031, 3, 2), EXPENSE, 600)]))
    old = split_layers(result.slices, result.direct)
    new = split_layers(result.slices, result.direct, _priced({dt.date(2031, 3, 2): 500.0}))
    assert old['expense_cash'] == pytest.approx(-1.0)                # the grams sold it spent
    assert new['expense_cash'] == pytest.approx(-1.2)                # 600 / 500: what the cash would have bought
    assert new['trading'] == pytest.approx(0.2)                      # 1.2 g worth, 1 g sold: the sale's
    assert sum(new.values()) == pytest.approx(sum(old.values()))


def test_the_whole_does_not_move_whatever_the_price():
    events = Events(openings=[Lot('إيرادات', D(2031, 3, 1, 9), 500, 0.0, kind=REVENUE), _sale(6000, 10, 1)],
                    closings=[Closing(D(2031, 3, 2), EXPENSE, 6200), Closing(D(2031, 3, 3), CUSTOMER, 300, 0.6)],
                    direct=[(D(2031, 3, 4), -0.3, EXPENSE_SIDE), (D(2031, 3, 4), 0.1, REVENUE_SIDE)])
    result = replay(events)
    whole = sum(s.result for s in result.slices) + sum(d[1] for d in result.direct)
    for price in (380.0, 500.0, 720.0):
        layers = split_layers(result.slices, result.direct, _priced({dt.date(2031, 3, 2): price}))
        assert sum(layers.values()) == pytest.approx(whole), price
        assert layers['expense_cash'] == pytest.approx(-6200 / price), price


def test_a_revenues_riyals_spent_are_the_revenues_in_two():
    # the expense spends the sale's first, then the revenue's: ② keeps what the revenue's 200 were worth
    events = Events(openings=[_sale(1000, 2, 1), Lot('إيرادات', D(2031, 3, 1, 11), 500, 0.0, kind=REVENUE)],
                    closings=[Closing(D(2031, 3, 2), EXPENSE, 1200)])
    result = replay(events)
    layers = split_layers(result.slices, result.direct, _priced({dt.date(2031, 3, 2): 400.0}))
    assert layers['expense_cash'] == pytest.approx(-3.0)             # 1,200 / 400
    assert layers['trading'] == pytest.approx(1000 / 400 - 2)        # the sale's 1,000 worth 2.5 g, 2 g sold
    assert layers['revenue_converted'] == pytest.approx(200 / 400)


def test_a_prepaid_piece_is_priced_on_its_payments_day_not_its_months():
    piece = Slice(D(2031, 4, 30, 23, 59), EXPENSE, 400.0, 0.0, 1.0, spent_at=D(2031, 3, 2, 23, 59))
    layers = split_layers([piece], [], _priced({dt.date(2031, 3, 2): 500.0, dt.date(2031, 4, 30): 400.0}))
    assert layers['expense_cash'] == pytest.approx(-0.8)             # 400 / 500, the payment's day
    assert layers['trading'] == pytest.approx(-0.2)


def test_a_day_with_no_price_costs_the_grams_sold_as_before():
    result = replay(Events(openings=[_sale(6000, 10, 1)], closings=[Closing(D(2031, 3, 2), EXPENSE, 600)]))
    layers = split_layers(result.slices, result.direct, _priced({}))
    assert layers['expense_cash'] == pytest.approx(-1.0) and layers['trading'] == pytest.approx(0.0)


# ── before any office price: the first supplier's purchase on or after the day ──

@pytest.fixture(scope='module')
def app():
    from app import app as flask_app
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def fenced(app, db_fence):
    yield


def _purchase(day, gold, grams, karat=21, wage=100.0, posted=True):
    from models import Invoice, InvoiceKaratLine, Supplier, db
    supplier = Supplier.query.first()
    inv = Invoice(invoice_type='شراء', invoice_type_id=900000 + day.day, date=day, total=gold + wage,
                  gold_subtotal=gold, wage_subtotal=wage, total_weight=grams, is_posted=posted,
                  supplier_id=supplier.id if supplier else None, gold_type='new')
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=karat, weight_grams=grams, gold_value_cash=gold,
                                    manufacturing_wage_cash=wage))
    db.session.flush()
    return inv


def test_before_any_office_price_the_first_purchase_on_or_after_the_day(fenced):
    from pricing.gold_price_service import get_main_karat
    from services.weight_position import expense_prices
    per_gram = 52391.0 / (100.0 * 21 / int(get_main_karat()))            # its grams in the main karat
    _purchase(D(2031, 2, 7, 1), gold=52391.0, grams=100.0)                 # 523.91 a 21k gram, wages aside
    _purchase(D(2031, 2, 9, 1), gold=60000.0, grams=100.0)
    _purchase(D(2031, 2, 5, 1), gold=70000.0, grams=100.0, posted=False)   # not posted: not read
    office = _priced({dt.date(2031, 2, 8): 540.0})                         # the office's from the 8th
    price_on = expense_prices(lambda day: office(day) if day >= dt.date(2031, 2, 8) else (0.0, 'لا سعر'),
                              dt.date(2031, 2, 28))
    assert price_on(dt.date(2031, 1, 10))[0] == pytest.approx(per_gram)     # the 7th's, the first after
    assert price_on(dt.date(2031, 2, 7))[0] == pytest.approx(per_gram)      # on the day itself
    assert 'شراء #' in price_on(dt.date(2031, 1, 10))[1]
    assert price_on(dt.date(2031, 2, 8))[0] == pytest.approx(540.0)         # an office price: the office's


def test_no_purchase_after_and_no_office_price_is_no_price(fenced):
    from services.weight_position import expense_prices
    price_on = expense_prices(lambda day: (0.0, 'لا سعر'), dt.date(2031, 2, 28))
    assert price_on(dt.date(2031, 2, 20)) == (0.0, 'لا سعر')
