"""Invoice 3020's karat-difference commission, never written (stage-4 item 9,
POST-001; the owner, 12 Oct 2026: «اعتمد الإصلاح»).

From 13 Jul to 29 Sep posting caught an ImportError and posted invoices
without their karat-difference entries. One invoice was hit: 3020, purchase
#178 from supplier 7, whose own fields say the company earns 307.37. The
entry posting would have written: dated as the invoice, keyed to it, debit the
supplier / credit 4110 -- written once, only as measured.

Run:
    python -m pytest tests/test_karat_diff_commission_repair.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, JournalEntry, Supplier, db
from services.repair.karat_diff_commission import NotAsMeasured, post_missing_commissions


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


NOW = datetime(2026, 10, 12, 12, 0)


def _uid():
    return uuid.uuid4().hex[:8]


def _purchase(earn=307.37, posted=True):
    account = Account(account_number=f'96{_uid()[:5]}', name=f'مورد {_uid()}', type='Liability')
    db.session.add(account)
    db.session.flush()
    supplier = Supplier(supplier_code=f'S-{_uid()}', name=f'مورد {_uid()}', account_id=account.id)
    db.session.add(supplier)
    db.session.flush()
    invoice = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء', date=datetime(2026, 9, 15),
                      total=1000.0, status='unpaid', supplier_id=supplier.id, is_posted=posted,
                      karat_diff_earn_total=earn, karat_diff_pay_total=0.0)
    db.session.add(invoice)
    db.session.flush()
    return invoice, account


@pytest.fixture
def revenue():
    found = Account.query.filter_by(account_number='4110').first()
    if found:
        return found
    a = Account(account_number='4110', name='خصم السداد بعيار أعلى', type='Revenue')
    db.session.add(a)
    db.session.flush()
    return a


def test_the_commission_posting_would_have_written_is_written_once(revenue):
    invoice, supplier_account = _purchase()
    measured = {invoice.id: 307.37}

    dry = post_missing_commissions(by='t', now=NOW, dry_run=True, measured=measured)
    assert dry[0]['amount'] == 307.37 and not dry[0]['written']
    assert not JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice.id).first()

    post_missing_commissions(by='t', now=NOW, dry_run=False, measured=measured)
    entry = JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice.id).one()
    assert entry.is_posted and entry.date == invoice.date
    lines = {l.account_id: l for l in entry.lines}
    assert lines[supplier_account.id].cash_debit == pytest.approx(307.37)
    assert lines[revenue.id].cash_credit == pytest.approx(307.37)
    assert post_missing_commissions(by='t', now=NOW, dry_run=False, measured=measured)[0]['done']


def test_an_invoice_not_as_measured_is_refused(revenue):
    invoice, _ = _purchase(earn=300.0)
    with pytest.raises(NotAsMeasured):
        post_missing_commissions(by='t', now=NOW, dry_run=True, measured={invoice.id: 307.37})
    unposted, _ = _purchase(posted=False)
    with pytest.raises(NotAsMeasured):
        post_missing_commissions(by='t', now=NOW, dry_run=True, measured={unposted.id: 307.37})
