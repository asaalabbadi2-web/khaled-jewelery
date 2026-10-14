"""CHART-002 step 4b2: a line tagged to a party counts on a shared account by the
account's place in the tree -- under the receivables / payables group (a role)
-- not by its number's prefix ('12%', '21%'). 2027 renumbers (ADR-044).
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT, SUPPLIER_PAYABLES_ROOT
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
from models import Account, Customer, JournalEntry, JournalEntryLine, Supplier, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _n():
    return uuid.uuid4().int % 10**6


def _account(number, kind, parent=None):
    account = Account(account_number=number, name=f'حساب {number}', type=kind, transaction_type='cash',
                      parent_id=parent)
    db.session.add(account)
    db.session.flush()
    return account


def _tagged(account, *, customer=None, supplier=None, debit=0.0, credit=0.0):
    other = _account(f'9{_n():06d}', 'Revenue')
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 10, 1), description='t',
                      is_posted=True, is_draft=False, entry_type='عادي')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=account.id, cash_debit=debit, cash_credit=credit,
                         customer_id=customer.id if customer else None, supplier_id=supplier.id if supplier else None),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=credit, cash_credit=debit)])
    db.session.flush()


def test_a_customer_line_on_a_shared_account_counts_by_the_tree_not_the_number():
    from services.party_live_balances import customer_line_clause
    receivables = require_account(DEFAULT_MAPPING_OPERATION_TYPE, CUSTOMER_RECEIVABLES_ROOT)
    customer = Customer(customer_code=f'C-{_n()}', name='عميل الشجرة')
    db.session.add(customer)
    db.session.flush()
    under_the_group = _account(f'88{_n():06d}', 'Asset', receivables)     # no «12» -- in the group
    numbered_like_it = _account(f'12{_n():06d}', 'Asset')                  # «12» -- outside the group
    _tagged(under_the_group, customer=customer, debit=300.0)
    _tagged(numbered_like_it, customer=customer, debit=50.0)

    lines = (JournalEntryLine.query.join(Account, JournalEntryLine.account_id == Account.id)
             .filter(customer_line_clause(customer.id, None, [])).all())
    assert {line.account_id for line in lines} == {under_the_group.id}


def test_a_supplier_line_on_a_shared_account_counts_by_the_tree_not_the_number():
    from services.party_live_balances import compute_live_supplier_balances
    payables = require_account(DEFAULT_MAPPING_OPERATION_TYPE, SUPPLIER_PAYABLES_ROOT)
    supplier = Supplier(supplier_code=f'S-{_n()}', name='مورد الشجرة')
    db.session.add(supplier)
    db.session.flush()
    _tagged(_account(f'88{_n():06d}', 'Liability', payables), supplier=supplier, credit=300.0)
    _tagged(_account(f'21{_n():06d}', 'Liability'), supplier=supplier, credit=50.0)

    assert abs(compute_live_supplier_balances([supplier])[supplier.id]['cash']) == pytest.approx(300.0)
