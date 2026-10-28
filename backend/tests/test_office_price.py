"""OFFICE-PRICE-1: the gold price is the closing office's, not the world ounce's.

The owner, 28 Oct 2026: the shop closes at the offices' price -- Dewan Al
Dahab's -- so sales and purchases are priced from it. Its formula, read from
its own page: the ounce plus its fees, a kilo of 24k at 32.148 ounces, 21k and
18k by its own divisors less a discount, and 22k from 21k (the owner). Its
figures that evening (ask 4066.55, fees 1.35 and 43): 495.59, 432.84, 370.79.

A price is priced by the terms it was saved with; one saved before carries
none and is priced by the ounce, as it was.

Run:
    python -m pytest tests/test_office_price.py -v
"""
import pathlib
import re
from datetime import datetime, timezone

import pytest

from app import app as flask_app
from models import GoldPrice, db
from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
from pricing.office_price import OfficeTerms, gram_price, row_gram_price, settings_terms, terms_of
from tests.test_gold_bought_enters_its_stock import world  # noqa: F401 (fixture)

DEWAN = OfficeTerms(main_fees_usd=1.35, custom_fees_usd=43.0, discount_21=0.75, discount_18=1.0)
ASK = 4066.55


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_the_office_prices_as_dewan_did():
    assert gram_price(ASK, 24, DEWAN) == pytest.approx(495.59, abs=0.005)
    assert gram_price(ASK, 21, DEWAN) == pytest.approx(432.84, abs=0.005)
    assert gram_price(ASK, 18, DEWAN) == pytest.approx(370.79, abs=0.005)
    assert gram_price(ASK, 22, DEWAN) == pytest.approx(gram_price(ASK, 21, DEWAN) * 22 / 21)


def test_a_price_saved_before_the_terms_is_priced_by_the_ounce():
    row = GoldPrice(price=ASK, date=datetime(2026, 10, 1))
    assert terms_of(row) is None
    assert row_gram_price(row, 21) == pytest.approx(ASK / TROY_OZ_TO_GRAMS * SAR_USD_PEG * 21 / 24)


def test_a_price_saved_with_terms_is_priced_by_them():
    from pricing.office_price import stamp
    row = stamp(GoldPrice(price=ASK, date=datetime(2026, 10, 29)), DEWAN)
    assert row_gram_price(row, 21) == pytest.approx(432.84, abs=0.005)


def test_a_saved_price_takes_the_settings_terms(app, monkeypatch):
    import gold_price
    monkeypatch.setattr(gold_price, '_push_to_commerce', lambda price: None)
    gold_price.save_gold_price(app, ASK)
    row = GoldPrice.query.order_by(GoldPrice.id.desc()).first()
    try:
        assert terms_of(row) == settings_terms()
    finally:
        GoldPrice.query.filter_by(id=row.id).delete()
        db.session.commit()


def test_the_price_the_screens_read_is_the_offices(app, auth_headers, monkeypatch):
    import routes.pricing as pricing
    from pricing.office_price import stamp
    monkeypatch.setattr(pricing, 'fetch_gold_price', lambda: None)   # no internet
    row = stamp(GoldPrice(price=ASK, date=datetime.now(timezone.utc).replace(tzinfo=None)), DEWAN)
    db.session.add(row)
    db.session.flush()
    body = app.test_client().get('/api/gold_price', headers=auth_headers).get_json()
    assert body['price_24k'] == pytest.approx(495.59, abs=0.005)
    assert body['prices_per_gram']['21']['sell'] == pytest.approx(432.84, abs=0.005)
    assert body['prices_per_gram']['18']['sell'] == pytest.approx(370.79, abs=0.005)
    assert set(body['opening_prices_per_gram']) == {'18', '21', '22', '24'}


BACKEND = pathlib.Path(__file__).resolve().parents[1]
SKIP = ('tests/', 'venv/', 'alembic/', 'tools/', 'devtools/', '.pytest_db')
CONVERTS = re.compile(r'TROY_OZ_TO_GRAMS|31\.1035')
# The ounce is turned into riyals a gram only in pricing/ -- and here, with the reason.
ALLOWED = {
    'services/gold_cost.py':
        'the opening price fallback averages the ounce of days before the office terms (ADR-042)',
}


def test_no_price_is_made_from_the_ounce_outside_pricing():
    found = set()
    for path in BACKEND.rglob('*.py'):
        rel = path.relative_to(BACKEND).as_posix()
        if rel.startswith('pricing/') or any(part in rel for part in SKIP):
            continue
        if CONVERTS.search(path.read_text(encoding='utf-8', errors='ignore')):
            found.add(rel)
    assert found == set(ALLOWED), f'ounce converted outside pricing/: {sorted(found - set(ALLOWED))}'


def test_new_terms_price_the_next_sale_at_once(app, auth_headers, monkeypatch):
    """The owner edits the office's terms; the price the screens read follows
    now -- a price saved with them -- and the prices before keep theirs."""
    import routes.pricing as pricing
    monkeypatch.setattr(pricing, 'fetch_gold_price', lambda: None)   # no internet
    from pricing.office_price import stamp
    before = stamp(GoldPrice(price=ASK, date=datetime.now(timezone.utc).replace(tzinfo=None)), DEWAN)
    db.session.add(before)
    db.session.commit()
    client = app.test_client()
    try:
        resp = client.put('/api/settings', headers=auth_headers, json={'office_custom_fees_usd': 40})
        assert resp.status_code == 200, resp.data
        body = client.get('/api/gold_price', headers=auth_headers).get_json()
        assert body['price_24k'] == pytest.approx(
            gram_price(ASK, 24, OfficeTerms(1.35, 40.0, 0.75, 1.0)), abs=0.005)
        db.session.expire_all()
        assert row_gram_price(GoldPrice.query.get(before.id), 24) == pytest.approx(495.59, abs=0.005)

        refused = client.put('/api/settings', headers=auth_headers, json={'office_discount_21': -1})
        assert refused.status_code == 400 and refused.get_json()['error'] == 'invalid_office_price_terms'
    finally:
        assert client.put('/api/settings', headers=auth_headers, json={'office_custom_fees_usd': 43}).status_code == 200
        GoldPrice.query.filter(GoldPrice.id >= before.id).delete()
        db.session.commit()


def test_a_price_entered_by_hand_is_quoted_by_the_office(app, auth_headers):
    """The manual screen takes an ounce or a 24k gram -- the office's gram, as
    Dewan shows it -- and the server says what it is in the other, and every karat."""
    from pricing.office_price import ounce_for_gram_24
    assert gram_price(ounce_for_gram_24(495.59, DEWAN), 24, DEWAN) == pytest.approx(495.59, abs=0.001)
    client = app.test_client()
    by_gram = client.get('/api/gold_price/quote?price_sar_per_gram_24k=495.59', headers=auth_headers).get_json()
    terms = settings_terms()
    assert by_gram['price_usd_per_oz'] == pytest.approx(ounce_for_gram_24(495.59, terms), abs=0.01)
    assert by_gram['prices_per_gram']['21']['sell'] == pytest.approx(
        gram_price(by_gram['price_usd_per_oz'], 21, terms), abs=0.01)
    by_ounce = client.get(f'/api/gold_price/quote?price_usd_per_oz={ASK}', headers=auth_headers).get_json()
    assert by_ounce['price_24k'] == pytest.approx(gram_price(ASK, 24, terms), abs=0.005)
    assert client.get('/api/gold_price/quote', headers=auth_headers).status_code == 400


def test_a_sale_is_measured_by_the_offices_sell_price_and_a_purchase_by_its_buy_price(app, auth_headers, world):
    """The owner, 29 Oct 2026: «أن يكون سعر بيع السوق (مكاتب التسكير) لفواتير
    البيع وسعر شراء السوق (مكاتب التسكير) لفواتير الشراء». A customer's scrap
    bought: its gold profit is the grams less what was paid at the buy price
    (the office's x the settings' ratio), and the grams its standing weight
    lost are worth the buy price when the seller typed none."""
    from models import Invoice
    from pricing.buy_price import buy_price_ratio
    from pricing.gold_price_service import get_current_gold_price, get_main_karat
    resp = app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': 'scrap',
        'transaction_type': 'buy', 'employee_id': world['holder'].id,
        'scrap_holder_employee_id': world['holder'].id, 'safe_box_id': world['pm'].default_safe_box_id,
        'date': datetime(2026, 10, 29, 12).isoformat(),
        'total': 1500.0, 'total_weight': 10.0, 'total_cost': 1500.0, 'total_tax': 0.0, 'amount_paid': 1500.0,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': 1500.0}],
        'items': [{'name': 'كسر', 'karat': 21, 'weight': 10.0, 'standing_weight': 11.0, 'stones_weight': 0.0,
                   'price': 1500.0, 'net': 1500.0, 'quantity': 1}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    invoice = db.session.get(Invoice, resp.get_json()['id'])
    now, ratio, main = get_current_gold_price(), buy_price_ratio(), get_main_karat()
    buy_main = now['price_per_gram_main_karat'] * ratio
    assert invoice.profit_gold == pytest.approx(10.0 * 21 / main - 1500.0 / buy_main, abs=0.001)
    assert invoice.profit_cash == pytest.approx(1.0 * now['price_per_gram_by_karat'][21] * ratio, abs=0.01)
