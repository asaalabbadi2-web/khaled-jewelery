"""CHART-002 step 2: a posting that needs an unmapped role is refused, whole.

The postings fell back on account numbers after the roles (511/512 for a
customer's scrap, 513 for purchase returns, 420 for sales returns, 521 for the
gold's cost) and skipped a commission line when its account was missing --
leaving the entry to an auto-balance. Now a role is its mapping: an amount on
an unmapped role refuses the invoice, which rolls back and says which role.
"""
import pytest

from app import app as flask_app
from models import AccountingMapping, Invoice, db
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


def test_the_refusal_names_the_role():
    from accounting.mappings import AccountNotMapped, VatAccountNotMapped, require_account
    with pytest.raises(AccountNotMapped) as refused:
        require_account('عملية لا وجود لها', 'دور لا وجود له')
    assert 'دور لا وجود له' in str(refused.value)
    assert issubclass(VatAccountNotMapped, AccountNotMapped)


def test_a_scrap_purchase_with_its_purchases_role_unmapped_is_refused(auth_headers, world):  # noqa: F811
    for row in AccountingMapping.query.filter(
            AccountingMapping.operation_type == 'شراء من عميل',
            AccountingMapping.account_type.in_(('purchases_gold_scrap', 'purchases_gold', 'purchases'))).all():
        row.is_active = False
    db.session.flush()
    before = Invoice.query.count()
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers,
                                        json=_payload(world, 'scrap_purchase_paid', held=False))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert 'purchases_gold_scrap' in resp.get_json()['detail']
    assert Invoice.query.count() == before
