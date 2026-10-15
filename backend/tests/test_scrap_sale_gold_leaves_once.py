"""A scrap sale's gold leaves its safe once, and nothing at startup deletes safe rows (STARTUP-SBT-1).

A scrap sale once wrote both invoice_scrap_sale and invoice_sale_gold_movement,
doubling its weight out of the safes (fixed by the inv_gold_type != 'scrap'
guard, 0255841e8). The sale's writer has since written its gold as
'invoice_gold' (UNPOST-001): without the guard, today, the 8 g leave twice --
invoice_scrap_sale and invoice_gold (measured, 15 Oct 2026). The rows it had written were removed by a «one-time fix»
in app.py that ran -- and committed -- on every start of every worker, and by
its twin, POST /api/safe-boxes/purge-duplicate-gold-movement-sbts. On the
production copies of 15 Oct 2026 there is none left to remove, so both went:
startup writes no data, and a repair is a migration or an entry, not a boot.

What keeps the class shut is the writer: this witness.
"""
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import SafeBoxTransaction, Settings, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _scrap_sale(world):
    """What the scrap sale screen sends (scrap_sales_invoice_screen.dart)."""
    return {'customer_id': world['customer'].id, 'invoice_type': 'بيع', 'transaction_type': 'sell',
            'gold_type': 'scrap', 'employee_id': world['holder'].id, 'date': datetime.now().isoformat(),
            'total': 4000.0, 'total_weight': 8.0, 'total_cost': 0.0, 'total_tax': 0.0,
            'amount_paid': 0.0, 'payments': [],
            'items': [{'name': 'كسر', 'karat': 22, 'weight': 8.0, 'price': 4000.0, 'net': 4000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 4000.0}]}


def _gold_out(invoice_id):
    """The rows taking the sale's gold out of a safe, and their grams."""
    rows = [r for r in SafeBoxTransaction.query.filter_by(invoice_id=invoice_id).all() if r.direction == 'out']
    return [r.ref_type for r in rows], sum(float(r.weight_22k or 0) for r in rows)


@pytest.mark.parametrize('posted_at_creation', [True, False])
def test_a_scrap_sale_s_gold_leaves_once(auth_headers, world, posted_at_creation):
    row = Settings.query.first() or Settings()
    row.auto_post_invoices = posted_at_creation
    db.session.add(row)
    db.session.flush()
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=_scrap_sale(world))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    invoice_id = resp.get_json()['id']
    if not posted_at_creation:
        g.pop('current_user', None)
        posted = flask_app.test_client().post(f'/api/invoices/post/{invoice_id}', headers=auth_headers)
        assert posted.status_code == 200, posted.get_data(as_text=True)[:300]
    # Posted at creation it is named invoice_scrap_sale; posted later, by the
    # plan, invoice_gold -- from the same safe. Either way, once.
    names, grams = _gold_out(invoice_id)
    assert len(names) == 1 and grams == pytest.approx(8.0), (names, grams)


def test_nothing_at_startup_or_by_a_button_deletes_them():
    import inspect
    import app as app_module
    assert 'invoice_sale_gold_movement' not in inspect.getsource(app_module)
    rules = {r.rule for r in flask_app.url_map.iter_rules()}
    assert '/api/safe-boxes/purge-duplicate-gold-movement-sbts' not in rules
