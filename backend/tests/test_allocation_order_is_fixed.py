"""A settlement takes its payments in one fixed order: oldest first, and among
payments of the same moment, the lower id first (CLEARING-SEL-1).

Production, 5 Oct 2026: invoice SELL-2026-1596 was paid by Mada in two parts,
330.00 (payment 3526) and 90.00 (payment 3527), saved in the same instant. The
allocation sorted by created_at alone, so for a partial amount which of the
two received it was whatever order the database happened to return (the query
has no ORDER BY). The test hands the rows back in both orders.

Run:
    python -m pytest tests/test_allocation_order_is_fixed.py -v
"""
from datetime import datetime

import pytest

from allocation_service import AllocationService
from app import app as flask_app
from models import Invoice, InvoicePayment, PaymentMethod, Voucher, db

_N = [0]


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _two_payments_of_one_moment():
    _N[0] += 1
    pm = PaymentMethod(payment_type='receivable', name=f'mada-order-{_N[0]}',
                       commission_rate=0.0, commission_fixed_amount=0.0,
                       commission_timing='settlement', auto_settlement_enabled=False,
                       is_active=True)
    inv = Invoice(invoice_type_id=900000 + _N[0], invoice_type='بيع',
                  date=datetime(2026, 10, 5), total=420.0)
    db.session.add_all([pm, inv])
    db.session.flush()
    moment = datetime(2026, 10, 5, 15, 52, 33)
    first = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id,
                           amount=330.0, net_amount=330.0, created_at=moment)
    second = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id,
                            amount=90.0, net_amount=90.0, created_at=moment)
    db.session.add(first)
    db.session.flush()
    db.session.add(second)
    db.session.flush()
    return first, second


def _voucher(gross):
    _N[0] += 1
    v = Voucher(voucher_number=f'T-ORDER-{_N[0]:05d}', voucher_type='adjustment',
                date=datetime(2026, 10, 6), amount_cash=gross, status='approved')
    db.session.add(v)
    db.session.flush()
    return v


class _RowsInOrder:
    """InvoicePayment.query whose rows come back in a chosen order."""
    def __init__(self, rows):
        self._rows = rows

    def filter(self, *_):
        return self

    def all(self):
        return list(self._rows)


@pytest.mark.parametrize('db_order', ['as_created', 'reversed'])
def test_a_partial_amount_goes_to_the_lower_id_of_one_moment(db_order, monkeypatch):
    first, second = _two_payments_of_one_moment()
    rows = [first, second] if db_order == 'as_created' else [second, first]
    monkeypatch.setattr(InvoicePayment, 'query', _RowsInOrder(rows))
    plan = AllocationService().build_allocation_plan(
        voucher=_voucher(90.0), invoice_payment_ids=[first.id, second.id],
        gross_amount=90.0)
    assert [(line.invoice_payment_id, line.amount_to_allocate) for line in plan.lines] \
        == [(first.id, 90.0)]
