"""Three clearing settlements whose untraced part is accepted (stage-4 item 10,
CLEAR-001; the owner, 12 Oct 2026).

AV-2026-00098 (Tamara, 2,105 of 3,000), AV-2026-00124 (Tamara, 895) and
AV-2026-00133 (Mada, 6,050 of 19,710) moved money from collection to the
Riyadh bank; no payment can be traced to those parts, so the scheduler's
repair phase failed on them and printed ❌ on every run. The books are
consistent -- each collection account's balance equals what its unsettled
payments owe (11 Oct backup: Mada 0 = 0, Tamara 13,720 = 13,720) -- and a
reversal would move the main bank and re-open receivables already collected.
The owner: no entry; the three are accepted -- only as measured. A gap that
moves is incomplete again.

Run:
    python -m pytest tests/test_untraceable_settlements_accepted.py -v
"""
import uuid
from datetime import datetime

import pytest

from allocation_repair_service import ACCEPTED_UNTRACEABLE, AllocationRepairService
from app import app as flask_app
from models import Account, SafeBox, Voucher, VoucherAccountLine, db


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


def _settlement(box, number, amount):
    v = Voucher(voucher_number=number, voucher_type='adjustment', date=datetime(2026, 5, 6), status='approved',
                reference_type='clearing_settlement', amount_cash=amount, created_by='t')
    db.session.add(v)
    db.session.flush()
    db.session.add(VoucherAccountLine(voucher_id=v.id, account_id=box.account_id, line_type='credit',
                                      amount_type='cash', amount=amount))
    db.session.flush()
    return v


@pytest.fixture
def box():
    acc = Account(account_number=f'15{_uid()}', name=f'تحصيل {_uid()}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    b = SafeBox(name=f'تمارا {_uid()}', safe_type='clearing', account_id=acc.id, is_active=True)
    db.session.add(b)
    db.session.flush()
    return b


def test_the_three_are_the_measured_ones():
    assert ACCEPTED_UNTRACEABLE == {'AV-2026-00098': 2105.0, 'AV-2026-00124': 895.0, 'AV-2026-00133': 6050.0}


def test_an_accepted_gap_is_not_repaired_again_and_a_moved_one_is(box):
    svc = AllocationRepairService()
    as_measured = _settlement(box, f'AV-T-{_uid()}', 895.0)
    moved = _settlement(box, f'AV-T-{_uid()}', 900.0)
    accepted = {as_measured.voucher_number: 895.0, moved.voucher_number: 895.0}
    found = {v.id for v in svc.find_incomplete_vouchers(safe_box=box, accepted=accepted)}
    assert as_measured.id not in found, 'accepted: the ❌ stops'
    assert moved.id in found, 'its gap moved: incomplete again'
    assert {v.id for v in svc.find_incomplete_vouchers(safe_box=box, accepted={})} == {as_measured.id, moved.id}
