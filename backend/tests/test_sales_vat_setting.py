"""VAT on sales is one company setting, and the server holds it (SALES-VAT-1).

Measured on the 6 Oct production copy: from the evening of 1 May 2026 every
sale carries no VAT -- 204 sales in May with 4 taxed, none from June to
October -- across every employee at once; before, 15 % inside the price. The
owner (7 Oct 2026): intended. But it rested on «فاتورة بدون ضريبة», a switch
kept on each device: a new device, cleared storage or a reset switch would
start charging 15 % again, unseen, while the company's setting says VAT is on.

The law: Settings.sales_vat_enabled. When off, a sale that carries VAT is
refused (sales_vat_disabled). Returns are not held to it: a return of a sale
taxed before May reverses that VAT. alembic 20261007_sales_vat_setting sets it
off where the recent sales prove it.

Run:
    python -m pytest tests/test_sales_vat_setting.py -v
"""
import importlib.util
import pathlib

import pytest

from app import app as flask_app
from models import Settings, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture(autouse=True)
def vat_payable(rollback_after_each):
    """As production: VAT on sales is owed on 2210."""
    from accounting.mappings import _ACCOUNT_NUMBER_CACHE
    from models import Account
    _ACCOUNT_NUMBER_CACHE.pop('2210', None)
    if not Account.query.filter_by(account_number='2210').first():
        db.session.add(Account(account_number='2210', name='ضريبة القيمة المضافة المستحقة',
                               type='Liability'))
        db.session.flush()
    yield
    _ACCOUNT_NUMBER_CACHE.pop('2210', None)


def _sales_vat(on):
    row = Settings.query.first() or Settings()
    row.tax_enabled = True
    row.tax_rate = 0.15
    row.auto_post_invoices = True
    row.sales_vat_enabled = on
    db.session.add(row)
    db.session.flush()


def _sale(w, *, tax):
    """A sale of 2 g of 21k at 1,150.00, VAT inside the price when taxed."""
    payload = _payload(w, 'sale_on_credit', held=False)
    payload['total'] = 1150.0
    payload['total_tax'] = tax
    item = payload['items'][0]
    item.update({'price': 1150.0, 'net': 1150.0 - tax, 'selling_price': 1150.0, 'tax': tax})
    return payload


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def test_with_sales_vat_off_a_taxed_sale_is_refused(auth_headers, world):
    _sales_vat(False)
    resp = _post(auth_headers, _sale(world, tax=150.0))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'sales_vat_disabled'


def test_with_sales_vat_off_an_untaxed_sale_is_taken(auth_headers, world):
    _sales_vat(False)
    resp = _post(auth_headers, _sale(world, tax=0.0))
    assert resp.status_code == 201, resp.get_json()


def test_with_sales_vat_on_a_taxed_sale_is_taken_as_before(auth_headers, world):
    _sales_vat(True)
    resp = _post(auth_headers, _sale(world, tax=150.0))
    assert resp.status_code == 201, resp.get_json()


def test_the_setting_is_read_and_saved(auth_headers, world):
    _sales_vat(True)
    resp = flask_app.test_client().put('/api/settings', headers=auth_headers,
                                       json={'sales_vat_enabled': False})
    assert resp.status_code == 200, resp.get_json()
    got = flask_app.test_client().get('/api/settings', headers=auth_headers).get_json()
    assert got['sales_vat_enabled'] is False


# ── the release's correction (alembic 20261007_sales_vat_setting) ───────────

def _migration():
    path = (pathlib.Path(__file__).resolve().parent.parent / 'alembic' / 'versions'
            / '20261007_sales_vat_setting.py')
    spec = importlib.util.spec_from_file_location('sales_vat_setting', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_recent_untaxed_sales_turn_the_setting_off(auth_headers, world):
    _sales_vat(True)
    for _ in range(3):
        assert _post(auth_headers, _sale(world, tax=0.0)).status_code == 201

    before, after, seen = _migration().correct_sales_vat(db.session.connection(), sample=3)

    assert (before, after, seen) == (True, False, 3)
    db.session.expire_all()
    assert Settings.query.first().sales_vat_enabled is False


def test_one_taxed_sale_among_the_recent_keeps_it_on(auth_headers, world):
    _sales_vat(True)
    assert _post(auth_headers, _sale(world, tax=0.0)).status_code == 201
    assert _post(auth_headers, _sale(world, tax=150.0)).status_code == 201

    before, after, _ = _migration().correct_sales_vat(db.session.connection(), sample=2)

    assert (before, after) == (True, True)
