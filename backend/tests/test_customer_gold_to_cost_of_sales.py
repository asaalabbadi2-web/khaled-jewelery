"""The gold sold that sat on the customers' weight twins, moved to where it belongs (CUSTGOLD-001).

The owner (5 Nov 2026): «تصحيح الكاتب ونقل الرصيد» and «قيد لكل شهر». Until
the writer was put right, a sale debited its customer's weight twin (712…)
for the grams it sold -- 19,495 g on the 2 Nov copy. The tool moves each
month's net, by one entry dated that month's last day, account by account:
a sale's (its return's, its correction's, its reversal's) to the cost of
sales by weight; a customer purchase's (16 in March-April 2026 credited the
twin) to its purchases by weight. Each month's balance sheet is then right.

What came from anything else is said, not moved. Run twice, it moves
nothing more: its own entries are in the net. dry_run writes nothing; an
audit row says what moved.

Run:
    python -m pytest tests/test_customer_gold_to_cost_of_sales.py -v
"""
import uuid
from datetime import datetime

import pytest

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
from models import Account, AuditLog, Invoice, JournalEntry, JournalEntryLine, db
from tests.test_gold_cost import _child, _role_twin

NOW = datetime(2041, 5, 3, 9)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _entry(when, account, cols, *, reference_type=None, reference_id=None):
    je = JournalEntry(entry_number=f'JE-CG-{uuid.uuid4().hex[:8]}', date=when, description='اختبار',
                      entry_type='عادي', reference_type=reference_type, reference_id=reference_id,
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='اختبار', **cols))
    db.session.flush()
    return je


def _invoice(kind, when, gold_type='new'):
    inv = Invoice(invoice_type_id=800000 + uuid.uuid4().int % 10**5, invoice_type=kind, gold_type=gold_type,
                  date=when, total=1.0)
    db.session.add(inv)
    db.session.flush()
    return inv


def _grams(account_id, *, month=None):
    q = (db.session.query(db.func.sum(JournalEntryLine.debit_21k - JournalEntryLine.credit_21k))
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(JournalEntryLine.account_id == account_id, JournalEntry.date >= datetime(2041, 1, 1)))
    if month:
        q = q.filter(db.func.to_char(JournalEntry.date, 'YYYY-MM') == month)
    return round(float(q.scalar() or 0.0), 3)


@pytest.fixture
def books():
    """In 2041: a customer's twin with 10 g sold in March, 4 g of it given
    back in April by a reversal, 2 g bought from him (scrap) in March, and
    1 g from a manual entry."""
    twin = _child(_role_twin('customer_receivables_root'), 'عميل CG وزني')
    sale = _invoice('بيع', datetime(2041, 3, 5))
    sold = _entry(datetime(2041, 3, 5, 12), twin, {'debit_21k': 10.0}, reference_type='invoice', reference_id=sale.id)
    _entry(datetime(2041, 4, 2, 12), twin, {'credit_21k': 4.0}, reference_type='journal_entry_reversal',
           reference_id=sold.id)
    bought = _invoice('شراء من عميل', datetime(2041, 3, 9), gold_type='scrap')
    _entry(datetime(2041, 3, 9, 12), twin, {'credit_21k': 2.0}, reference_type='invoice', reference_id=bought.id)
    manual = _entry(datetime(2041, 3, 20, 12), twin, {'debit_21k': 1.0}, reference_type='manual')
    scrap_purchases = db.session.get(Account, get_account_id_for_mapping('شراء من عميل', 'purchases_gold_scrap'))
    if not scrap_purchases.memo_account_id:                            # production's 7512
        from account_pair_service import link_accounts
        twin_7512 = Account(account_number=f'7512{uuid.uuid4().int % 10**4:04d}', name='مشتريات كسر وزني CG',
                            type='Expense', transaction_type='gold', tracks_weight=True)
        db.session.add(twin_7512)
        db.session.flush()
        link_accounts(scrap_purchases, twin_7512, created_by='t')
    return {'twin': twin, 'manual': manual,
            'sold_weight': get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_cost_of_sales_weight'),
            'bought_weight': scrap_purchases.memo_account_id}


def test_each_month_moves_at_its_last_day_to_where_it_belongs(books):
    from services.repair.customer_gold_to_cost_of_sales import move
    plan = move(by='t', now=NOW)
    assert _grams(books['sold_weight']) == 0, 'dry by default'
    assert {(m['month'], m['kind']) for m in plan['months'] if m['month'].startswith('2041')} == \
        {('2041-03', 'sold'), ('2041-04', 'sold'), ('2041-03', 'bought-scrap')}

    move(by='t', now=NOW, dry_run=False)
    assert _grams(books['twin'].id) == pytest.approx(1.0), 'only the manual gram stays'
    assert _grams(books['sold_weight'], month='2041-03') == pytest.approx(10.0)
    assert _grams(books['sold_weight'], month='2041-04') == pytest.approx(-4.0)
    assert _grams(books['bought_weight'], month='2041-03') == pytest.approx(-2.0)
    march = JournalEntry.query.filter_by(reference_type='customer_gold_moved',
                                         reference_number='CUSTGOLD-2041-03-sold').one()
    assert march.date == datetime(2041, 3, 31, 23, 59)
    assert any(left['entry_id'] == books['manual'].id for left in plan['left']), 'said, not moved'
    assert AuditLog.query.filter_by(action='repair_customer_gold_to_cost_of_sales').count() >= 1


def test_run_twice_it_moves_nothing_more(books):
    from services.repair.customer_gold_to_cost_of_sales import move
    move(by='t', now=NOW, dry_run=False)
    again = move(by='t', now=NOW, dry_run=False)
    assert not [m for m in again['months'] if m['month'].startswith('2041')]
    assert _grams(books['sold_weight'], month='2041-03') == pytest.approx(10.0)


def test_the_month_not_over_is_dated_now(books):
    from services.repair.customer_gold_to_cost_of_sales import move
    sale = _invoice('بيع', datetime(2041, 5, 1))
    _entry(datetime(2041, 5, 1, 10), books['twin'], {'debit_21k': 3.0}, reference_type='invoice', reference_id=sale.id)
    move(by='t', now=NOW, dry_run=False)
    may = JournalEntry.query.filter_by(reference_type='customer_gold_moved',
                                       reference_number='CUSTGOLD-2041-05-sold').one()
    assert may.date == NOW
