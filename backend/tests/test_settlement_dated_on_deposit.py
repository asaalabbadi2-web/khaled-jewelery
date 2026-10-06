"""The scheduler dates each settlement the day its money reached the bank (ADR-037).

End to end: a sale paid by card through POST /api/invoices (its payment, its
posted entry on the clearing account), then the scheduler run on a chosen day,
then the voucher and its entry -- the line the Riyadh bank statement shows.

Before (6 Oct 2026): a daily method's settlement was dated the SALE day, a
weekly one the moment the scheduler ran, and Tabby's Monday deposit was split
into one voucher per sale day.

Run:
    python -m pytest tests/test_settlement_dated_on_deposit.py -v
"""
import uuid
from datetime import datetime, timedelta

import pytest
from flask import g

from app import app as flask_app
from clearing_settlement_scheduler import ClearingSettlementScheduler
from models import Account, Customer, InvoicePayment, JournalEntry, PaymentMethod, SafeBox, SettlementLine, Voucher, db
from tests.retraction_world import world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


def _card(world, **schedule):
    clearing_acc = Account(account_number=f'84{uuid.uuid4().int % 10**6:06d}', name=f'مقاصة {_uid()}', type='Asset')
    bank_acc = Account(account_number=f'85{uuid.uuid4().int % 10**6:06d}', name=f'بنك {_uid()}', type='Asset')
    db.session.add_all([clearing_acc, bank_acc])
    db.session.flush()
    box = SafeBox(name=f'بطاقة {_uid()}', safe_type='clearing', account_id=clearing_acc.id, is_active=True)
    bank = SafeBox(name=f'بنك {_uid()}', safe_type='bank', account_id=bank_acc.id, is_active=True)
    db.session.add_all([box, bank])
    db.session.flush()
    pm = PaymentMethod(payment_type='mada', name=f'بطاقة {_uid()}', commission_rate=0.0,
                       commission_timing='settlement', is_active=True, default_safe_box_id=box.id,
                       auto_settlement_enabled=True, settlement_bank_safe_box_id=bank.id, **schedule)
    db.session.add(pm)
    db.session.flush()
    return {'world': world, 'pm': pm, 'box': box, 'bank': bank}


def _sale(headers, card, amount, sold_at):
    body = {'customer_id': Customer.query.first().id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': card['world']['holder'].id, 'date': datetime.now().isoformat(),
            'total': amount, 'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': amount,
            'payments': [{'payment_method_id': card['pm'].id, 'amount': amount}],
            'items': [{'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'price': amount, 'net': amount,
                       'quantity': 1, 'wage': 0, 'selling_price': amount}]}
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json=body)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    ip = InvoicePayment.query.filter_by(invoice_id=resp.get_json()['id']).one()
    ip.created_at = sold_at          # the sale day the payment belongs to
    db.session.flush()
    return ip


def _run(day):
    return ClearingSettlementScheduler(flask_app).process_due_settlements(today=day)


def _settlements(card):
    return (Voucher.query.filter(Voucher.reference_type == 'clearing_settlement',
                                 Voucher.reference_number.like(f'AUTO-PM-{card["pm"].id}-B-%'))
            .order_by(Voucher.date).all())


# A Monday: 5 Oct 2026.
MON = datetime(2026, 10, 5, 10, 0)


def test_a_daily_deposit_is_dated_the_next_day_even_when_the_run_is_late(auth_headers, world):
    card = _card(world, settlement_schedule_type='days', deposit_delay_days=1)
    ip = _sale(auth_headers, card, 300.0, MON)

    _run(MON.date())
    assert _settlements(card) == [], 'the money reaches the bank on Tuesday'

    _run(MON.date() + timedelta(days=3))           # the scheduler was down until Thursday
    [v] = _settlements(card)
    assert v.date.date() == (MON + timedelta(days=1)).date()
    assert JournalEntry.query.get(v.journal_entry_id).date.date() == v.date.date(), 'the bank line has the same date'
    assert SettlementLine.query.filter_by(invoice_payment_id=ip.id).one().amount_settled == 300.0

    _run(MON.date() + timedelta(days=4))
    assert len(_settlements(card)) == 1, 'a settled deposit is not settled again'


def test_a_weekly_deposit_is_one_voucher_dated_its_monday(auth_headers, world):
    """Tabby: the sales up to Sunday reach the bank on Monday -- one transfer."""
    card = _card(world, settlement_schedule_type='weekday', settlement_weekday=6,
                 deposit_schedule_type='weekday', deposit_weekday=0)
    for day, amount in ((0, 100.0), (2, 250.0), (6, 50.0)):       # Mon, Wed, Sun
        _sale(auth_headers, card, amount, MON + timedelta(days=day))

    _run(MON.date() + timedelta(days=7))
    [v] = _settlements(card)
    assert v.date.date() == (MON + timedelta(days=7)).date()
    assert float(v.amount_cash) == 400.0


def test_a_flexible_plan_waits_for_its_minimum_and_then_deposits_once(auth_headers, world):
    """Tamara's flexible plan: below the minimum the week waits; the next week
    carries both, on its Wednesday."""
    card = _card(world, settlement_schedule_type='weekday', settlement_weekday=4,
                 deposit_schedule_type='weekday', deposit_weekday=2, min_settlement_amount=500.0)
    _sale(auth_headers, card, 300.0, MON)                        # week ending Fri 9 Oct
    _run(MON.date() + timedelta(days=9))                         # Wed 14 Oct
    assert _settlements(card) == []

    _sale(auth_headers, card, 300.0, MON + timedelta(days=7))    # week ending Fri 16 Oct
    _run(MON.date() + timedelta(days=16))                        # Wed 21 Oct
    [v] = _settlements(card)
    assert v.date.date() == (MON + timedelta(days=16)).date() and float(v.amount_cash) == 600.0
