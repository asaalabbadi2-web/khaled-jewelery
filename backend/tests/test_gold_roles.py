"""CHART-002 step 4: the gold's inventory, the weight closing's bridge and the
karat-difference commission are roles -- found by their mapping, never by a
number, never made by the code.

Until now: the invoices found the gold's financial inventory by the weight-
closing settings' numbers (1300 / 1310, the code's own defaults); the weight
closing by one setting read as a row id first (1310 for new gold and scrap
alike -- a row 1310 is five accounts away on the production copy); the bridge
as 1710 / 1290 / a name; and the commission made 4110 and 5240 when missing.
And when the inventory finder found nothing, five invoice types fell back on
the per-karat roles -- mapped on production to the WEIGHT inventory, 71300 --
for a cash amount.
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, AccountNotMapped, get_account_id_for_mapping
from models import Account, AccountingMapping, Invoice, Settings, Supplier, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _unmap(role):
    for row in AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                                 account_type=role).all():
        row.is_active = False
    db.session.flush()


def test_new_gold_and_scrap_have_each_their_inventory_whatever_the_old_setting_says():
    from routes import _gold_inventory_account_id, _resolve_inventory_account_id_for_invoice
    row = Settings.query.first() or Settings()
    row.weight_closing_settings = '{"inventory_account_id": 1310}'   # the old default, read as a row id first
    db.session.add(row)
    db.session.flush()
    new = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_inventory_new')
    scrap = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_inventory_scrap')
    assert new and scrap and new != scrap
    assert _gold_inventory_account_id('new') == new
    assert _gold_inventory_account_id('scrap') == scrap
    assert _resolve_inventory_account_id_for_invoice('بيع', 'new') == new
    assert _resolve_inventory_account_id_for_invoice('شراء من عميل', 'new') == scrap


def test_a_sale_with_its_inventory_role_unmapped_is_refused(auth_headers, world):  # noqa: F811
    _unmap('gold_inventory_new')
    before = Invoice.query.count()
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers,
                                        json=_payload(world, 'sale_on_credit', held=False))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert 'gold_inventory_new' in resp.get_data(as_text=True)
    assert Invoice.query.count() == before


def test_a_commission_with_its_role_unmapped_is_refused_and_no_account_is_made():
    from accounting.karat_diff_commission import EXPENSE_ROLE, write_karat_diff_commission
    from party_account_service import ensure_supplier_accounts
    supplier = Supplier(supplier_code=f'SUP-{uuid.uuid4().hex[:6]}', name=f'مورد {uuid.uuid4().hex[:6]}')
    db.session.add(supplier)
    db.session.flush()
    ensure_supplier_accounts(supplier)
    invoice = Invoice(invoice_type_id=uuid.uuid4().int % 900000 + 1, invoice_type='شراء',
                      date=datetime(2026, 10, 14), total=1000.0, status='unpaid', supplier_id=supplier.id,
                      karat_diff_earn_total=0.0, karat_diff_pay_total=120.0)
    db.session.add(invoice)
    db.session.flush()
    _unmap(EXPENSE_ROLE)
    accounts = Account.query.count()
    with pytest.raises(AccountNotMapped) as refused:
        write_karat_diff_commission(invoice, reference_type='invoice', label='t', by='t', now=datetime(2026, 10, 14))
    assert refused.value.role == EXPENSE_ROLE
    assert Account.query.count() == accounts


def test_the_per_karat_roles_are_asked_for_nowhere():
    """Their only readers were the fallbacks deleted here: no posting asks for
    them, so the registry -- and the nightly check -- no longer require them."""
    from accounting.mappings import REQUIRED_ROLES
    assert not [pair for pair in REQUIRED_ROLES if pair[1].startswith('inventory_') and pair[1].endswith('k')]
    import pathlib
    root = pathlib.Path(__file__).resolve().parents[1]
    for path in ('routes/invoices.py', 'routes/__init__.py', 'accounting/weight_closing.py'):
        assert "f'inventory_{karat}k'" not in (root / path).read_text(encoding='utf-8'), path
