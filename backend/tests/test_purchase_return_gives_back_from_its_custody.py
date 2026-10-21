"""A customer purchase's return gives the gold back from the safe its purchase put it in.

The owner (21 Oct 2026): «يخرج من العهدة التي دخلها؛ حتى وإن سُحب الذهب منها
يُعاد إليها بتحويل». The return chose its safe by people -- the holder the
request named, else the invoice's employee (the user who made the return),
else the original's -- so a full reversal made by another employee took the
gold out of their own custody, not the one it went into. The safe is now read
from the purchase's own posted entry: the gold safe its gold entered.

Run:
    python -m pytest tests/test_purchase_return_gives_back_from_its_custody.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Employee, Invoice, JournalEntry, JournalEntryLine, SafeBox, db
from tests.test_gold_bought_enters_its_stock import _purchase, world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _other_holder():
    """Another employee with a custody of their own."""
    custody = Account(account_number=f'79{uuid.uuid4().int % 10**6:06d}', name='عهدة أخرى', type='Asset',
                      transaction_type='gold', tracks_weight=True)
    db.session.add(custody)
    db.session.flush()
    box = SafeBox(name=f'عهدة أخرى {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=custody.id,
                  stock_location='custody', is_active=True)
    db.session.add(box)
    db.session.flush()
    other = Employee(employee_code=f'E-{uuid.uuid4().hex[:6]}', name='موظف آخر', salary=0.0, is_active=True,
                     gold_safe_box_id=box.id)
    db.session.add(other)
    db.session.flush()
    return other, custody


def _grams_on(account_id, invoice_id):
    db.session.expire_all()
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id,
                                                         is_deleted=False)]
    return round(sum(float(l.debit_21k or 0) - float(l.credit_21k or 0) for l in JournalEntryLine.query.filter(
        JournalEntryLine.journal_entry_id.in_(entries or [-1]), JournalEntryLine.account_id == account_id,
        JournalEntryLine.is_deleted.is_(False))), 3)


def test_the_return_gives_back_from_the_custody_the_purchase_filled(auth_headers, world):
    bought = _purchase(auth_headers, world)
    assert _grams_on(world['custody'].id, bought['id']) == pytest.approx(10.0)
    other, other_custody = _other_holder()
    item = Invoice.query.get(bought['id']).items[0]
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'مرتجع شراء', 'gold_type': 'scrap',
        'original_invoice_id': bought['id'], 'return_reason': 'عيب',
        'scrap_holder_employee_id': other.id, 'employee_id': other.id,     # someone else hands it back
        'date': datetime(2026, 10, 21, 13).isoformat(),
        'total': 1500.0, 'total_weight': 10.0, 'total_tax': 0.0, 'total_cost': 1500.0, 'amount_paid': 1500.0,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': 1500.0}],
        'items': [{'original_invoice_item_id': item.id, 'name': 'كسر', 'karat': 21, 'weight': 10.0,
                   'quantity': 1, 'cost': 1500.0, 'net': 1500.0, 'tax': 0.0, 'price': 1500.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    returned = resp.get_json()['id']
    assert _grams_on(world['custody'].id, returned) == pytest.approx(-10.0), 'out of the custody it went into'
    assert _grams_on(other_custody.id, returned) == pytest.approx(0.0), 'not the one handing it back'
