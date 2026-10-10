"""Stage-4 item 8: an old office reservation's gold came from a purchase, not from
our scrap stock (the owner, 11 Oct 2026).

services/repair/office_reservation_weights.py: each old reservation weight entry
that credited the scrap stock (71310) gets a transfer, dated as it, debit 71310 /
credit the purchases' weight twin 7512, karat by karat; no cash. On the 10 Oct
copy: 27 entries, 6,083.506 g at the main karat; 71310 from -6,140.649 to
-57.143 (a real scrap sale); cash and entries otherwise untouched.

Run:
    python -m pytest tests/test_office_reservation_weights_repair.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from services.repair.office_reservation_weights import (
    TRANSFER, NotAsMeasured, transfer_office_reservation_weights,
)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


NOW = datetime(2026, 10, 11, 12, 0)


def _account(number, name):
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=name, type='Asset')
    db.session.add(a)
    db.session.flush()
    return a


def _reservation_entry(scrap, office, *, credit_24k=0.0, debit_21k=0.0, date=datetime(2026, 9, 1)):
    je = JournalEntry(entry_number=f'WGT-T-{uuid.uuid4().hex[:6]}', date=date, description='إرسال ذهب للحجز',
                      entry_type='عادي', reference_type='office_reservation', reference_id=1,
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=scrap.id, credit_24k=credit_24k, debit_21k=debit_21k,
                         weight_type='ANALYTICAL', description='خروج ذهب كسر للتسكير'),
        JournalEntryLine(journal_entry_id=je.id, account_id=office.id, debit_24k=credit_24k, credit_21k=debit_21k,
                         weight_type='ANALYTICAL', description='مكتب'),
    ])
    db.session.flush()
    return je


@pytest.fixture
def accounts():
    return {'scrap': _account('71310', 'مخزون الذهب ـ كسر وزني'),
            'twin': _account('7512', 'مشتريات ذهب كسر من العملاء وزني'),
            'office': _account(f'721{uuid.uuid4().hex[:5]}', 'مكتب اختبار وزني')}


def test_each_old_entry_gets_its_transfer_dated_as_it(accounts):
    old = _reservation_entry(accounts['scrap'], accounts['office'], credit_24k=100.0)

    dry = transfer_office_reservation_weights(by='t', now=NOW, dry_run=True)
    assert old.id in {p['entry_id'] for p in dry['entries']}
    assert not JournalEntry.query.filter_by(reference_type=TRANSFER, reference_id=old.id).first(), 'dry run writes nothing'

    transfer_office_reservation_weights(by='t', now=NOW, dry_run=False)

    transfer = JournalEntry.query.filter_by(reference_type=TRANSFER, reference_id=old.id).one()
    assert transfer.date == old.date and transfer.is_posted
    by_account = {l.account_id: l for l in transfer.lines}
    assert by_account[accounts['scrap'].id].debit_24k == pytest.approx(100.0)
    assert by_account[accounts['twin'].id].credit_24k == pytest.approx(100.0)
    assert all(not (l.cash_debit or l.cash_credit) for l in transfer.lines), 'weight only'
    again = transfer_office_reservation_weights(by='t', now=NOW, dry_run=True)
    assert old.id not in {p['entry_id'] for p in again['entries']}


def test_a_rounding_remainder_is_skipped_and_said(accounts):
    tiny = _reservation_entry(accounts['scrap'], accounts['office'], credit_24k=0.0001)
    plan = transfer_office_reservation_weights(by='t', now=NOW, dry_run=True)
    assert tiny.id not in {p['entry_id'] for p in plan['entries']}
    assert tiny.entry_number in {s['entry_number'] for s in plan['skipped']}


def test_an_entry_that_puts_gold_into_the_scrap_stock_is_refused(accounts):
    _reservation_entry(accounts['scrap'], accounts['office'], debit_21k=5.0)
    with pytest.raises(NotAsMeasured):
        transfer_office_reservation_weights(by='t', now=NOW, dry_run=True)
