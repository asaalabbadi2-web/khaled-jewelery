"""Stage-4 item 21: two office reservations paid in cash in March, whose gold the
books then owed back to the office (11 Oct 2026, found by ADR-042 phase 2).

Reservations 8 and 43 (مكاتب تسكير فورية واشخاص, 52,478 + 63,900 = 116,378)
were paid by voucher in March. Their gold, 185.4 g of 24k, reached the scrap
safe by AV-2026-00012 (JE-2026-00939, 18 March) -- credit the office's weight
account, which had never been debited: the books say we owe the office 185.4 g.
The price went to purchases only on 29 July, by a manual entry (JE-2026-04561).

services/repair/march_reservations_purchase.py writes two entries, never an
edit: on the transfer's date, the purchase -- the office's weight account
debited, the purchases' weight twin 7512 credited, 512 debited and the office's
cash account credited for the price; on the manual entry's date, its reversal.
The office's gold debt goes to zero, the price lands in March with its gold,
and the moving average sees a purchase at its price.

Run:
    python -m pytest tests/test_march_reservations_purchase_repair.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from services.repair.march_reservations_purchase import (
    PURCHASE, NotAsMeasured, record_march_reservations_purchase,
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


def _account(number, name, parent=None):
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=name, type='Asset', parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _entry(when, lines):
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:8]}', date=when, description='اختبار',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, weight_type='ANALYTICAL',
                                        description='اختبار', **cols))
    db.session.flush()
    return je


@pytest.fixture
def books():
    tag = uuid.uuid4().hex[:5]
    b = {
        'safe': _account(f'71310{tag}', 'صندوق كسر اختبار', _account('71310', 'مخزون الذهب ـ كسر وزني')),
        'office_weight': _account(f'7210{tag}', 'مكتب اختبار وزني', _account('7210', 'موردو الذهب المشغول وزني')),
        'office_cash': _account(f'2100{tag}', 'مكتب اختبار'),
        'purchases': _account('512', 'مشتريات ذهب كسر من العملاء'),
        'twin': _account('7512', 'مشتريات ذهب كسر من العملاء وزني'),
        'bank': _account(f'1110{tag}', 'بنك اختبار'),
    }
    b['paid'] = _entry(datetime(2032, 3, 12), [(b['office_cash'], {'cash_debit': 116378}),
                                                 (b['bank'], {'cash_credit': 116378})])
    b['transfer'] = _entry(datetime(2032, 3, 18), [(b['safe'], {'debit_24k': 185.4}),
                                                     (b['office_weight'], {'credit_24k': 185.4})])
    b['settled'] = _entry(datetime(2032, 7, 29), [(b['purchases'], {'cash_debit': 116378}),
                                                    (b['office_cash'], {'cash_credit': 116378})])
    return b


def _run(b, dry_run):
    return record_march_reservations_purchase(
        by='t', now=NOW, dry_run=dry_run, transfer_entry=b['transfer'].entry_number,
        settlement_entry=b['settled'].entry_number, office_weight=b['office_weight'].account_number,
        office_cash=b['office_cash'].account_number, reservation_ids=())


def _balance(account, col):
    return sum(float(getattr(l, f'debit_{col}') or 0) - float(getattr(l, f'credit_{col}') or 0)
               for l in JournalEntryLine.query.filter_by(account_id=account.id, is_deleted=False))


def test_the_purchase_lands_with_its_gold_and_the_office_owes_nothing(books):
    b = books
    plan = _run(b, dry_run=True)
    assert (plan['grams_24k'], plan['amount']) == (pytest.approx(185.4), pytest.approx(116378))
    assert not JournalEntry.query.filter_by(reference_type=PURCHASE).filter(
        JournalEntry.reference_id == b['transfer'].id).first(), 'a dry run writes nothing'

    done = _run(b, dry_run=False)

    purchase = JournalEntry.query.filter_by(reference_type=PURCHASE, reference_id=b['transfer'].id).one()
    reversal = JournalEntry.query.filter_by(reference_type='journal_entry_reversal', reference_id=b['settled'].id).one()
    assert purchase.date == b['transfer'].date and reversal.date == b['settled'].date
    assert _balance(b['office_weight'], '24k') == pytest.approx(0), 'the office owes nothing in gold'
    assert _balance(b['twin'], '24k') <= -185.4 + 1e-6
    office_cash = sum(float(l.cash_debit or 0) - float(l.cash_credit or 0)
                      for l in JournalEntryLine.query.filter_by(account_id=b['office_cash'].id, is_deleted=False))
    assert office_cash == pytest.approx(0)
    by_month = {}
    for je in (purchase, reversal, b['settled']):
        for l in je.lines:
            if l.account_id == b['purchases'].id:
                key = je.date.strftime('%Y-%m')
                by_month[key] = by_month.get(key, 0) + float(l.cash_debit or 0) - float(l.cash_credit or 0)
    assert by_month == {'2032-03': pytest.approx(116378), '2032-07': pytest.approx(0)}, 'the price in March'
    assert done['entries'] == [purchase.entry_number, reversal.entry_number]
    assert _run(b, dry_run=True)['done'], 'a second run finds it done'


def test_the_average_sees_a_purchase_at_its_price(books):
    from services.gold_cost import replay
    _run(books, dry_run=False)
    r = replay(opening_price=0.0, since=date(2032, 1, 1))
    m = r.months['2032-03']
    assert m.purchases_g == pytest.approx(185.4 * 24 / 21)
    assert m.purchases_value == pytest.approx(116378)


def test_an_office_debt_already_moved_is_refused(books):
    b = books
    _entry(datetime(2032, 5, 1), [(b['office_weight'], {'debit_24k': 50}), (b['safe'], {'credit_24k': 50})])
    with pytest.raises(NotAsMeasured):
        _run(b, dry_run=True)
