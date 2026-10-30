"""The manager's dashboard says what is ours and what we owe (DASH-4).

The owner, 30 Oct 2026, agreeing to all advised: the liquidity card said the
customers' cash we are owed and nothing else -- what we owe the suppliers was
read from customers typed «مورد» (the suppliers are their own table: it read
nothing, and the coverage ratio with it), the gold either way was not said,
and our gold at the offices (ADR-052) was not either. Now one reading, by the
ledger's own readers (compute_live_*_balances, the office deposits): cash and
main-karat grams, ours and theirs.

Run:
    python -m pytest tests/test_dashboard_says_what_is_ours_and_what_we_owe.py -v
"""
import uuid
from datetime import datetime

import pytest

from models import Account, Customer, JournalEntry, JournalEntryLine, Supplier, db
from tests.office_deposit import give_deposit


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _positions(app, headers):
    return app.test_client().get('/api/dashboard/admin/standing', headers=headers).get_json()['positions']


def _line(account, *, supplier=None, customer=None, cash_debit=0.0, cash_credit=0.0, debit_21k=0.0, credit_21k=0.0):
    je = JournalEntry(entry_number=f'JE-P-{uuid.uuid4().hex[:8]}', date=datetime.now(), description='رصيد',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id,
                                    supplier_id=supplier.id if supplier else None,
                                    customer_id=customer.id if customer else None,
                                    cash_debit=cash_debit, cash_credit=cash_credit,
                                    debit_21k=debit_21k, credit_21k=credit_21k, description='رصيد'))
    db.session.flush()


def test_what_the_suppliers_customers_and_offices_hold_is_said(app, auth_headers):
    from pricing.gold_price_service import get_main_karat
    main = float(get_main_karat())
    before = _positions(app, auth_headers)

    payable = Account(account_number=f'21{uuid.uuid4().int % 10**6:06d}', name='مورد اختبار', type='Liability',
                      transaction_type='both', tracks_weight=True)
    receivable = Account(account_number=f'12{uuid.uuid4().int % 10**6:06d}', name='عميل اختبار', type='Asset',
                         transaction_type='both', tracks_weight=True)
    db.session.add_all([payable, receivable])
    db.session.flush()
    supplier = Supplier(supplier_code=f'S-P-{uuid.uuid4().hex[:6]}', name='مورد مراكز', account_id=payable.id)
    customer = Customer(customer_code=f'C-P-{uuid.uuid4().hex[:6]}', name='عميل مراكز', account_id=receivable.id)
    office_supplier = Supplier(supplier_code=f'S-O-{uuid.uuid4().hex[:6]}', name='مكتب مراكز')
    db.session.add_all([supplier, customer, office_supplier])
    db.session.flush()
    _line(payable, supplier=supplier, cash_credit=1000.0, credit_21k=5.0)        # we owe 1,000 and 5 g
    _line(receivable, customer=customer, cash_debit=300.0, debit_21k=2.0)        # owes us 300 and 2 g
    deposit = give_deposit(office_supplier)
    deposit_account = db.session.get(Account, deposit.account_id)
    _line(deposit_account, debit_21k=7.0)                                         # 7 g of ours at the office

    after = _positions(app, auth_headers)

    def moved(side, key):
        return round(after[side][key] - before[side][key], 3)
    assert moved('suppliers', 'we_owe_cash') == pytest.approx(1000.0)
    assert moved('suppliers', 'we_owe_gold') == pytest.approx(5.0 * 21 / main, abs=0.001)
    assert moved('customers', 'owe_us_cash') == pytest.approx(300.0)
    assert moved('customers', 'owe_us_gold') == pytest.approx(2.0 * 21 / main, abs=0.001)
    assert round(after['offices_gold'] - before['offices_gold'], 3) == pytest.approx(7.0 * 21 / main, abs=0.001)
