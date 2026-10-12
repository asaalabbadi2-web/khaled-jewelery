"""A karat-difference commission is written once, by one writer, however its
document is posted (item 9's cause; the owner, 12 Oct 2026: «ابدأ»).

Measured on the 11 Oct backup: invoice 3020 -- the year's only purchase with
a karat-difference commission -- was posted AT CREATION (3 seconds after its
date; auto_post_invoices is on, and all 67 purchases since July were posted
so). The creation path writes no commission at all: only the later posting
(post_invoice_document) called the builder. So the fault was not the July
import alone -- it is live: the next purchase with a commission, posted at
creation, loses it.

And the commission had two writers: the invoice's
(routes/invoices._create_karat_diff_settlement_entries) and the voucher's
(posting_routes._create_and_post_karat_diff_entries_for_voucher) -- the same
accounts, the same rule, two copies, each skipping silently when the supplier
has no account.

The law: a purchase with a commission, posted at creation or later, and an
approved payment voucher with one, each carry exactly one commission entry --
debit the supplier / credit 4110 for what the company earns, debit 5240 /
credit the supplier for what it pays; one writer
(accounting/karat_diff_commission.py); a supplier with no account refuses the
posting instead of losing the entry.

Run:
    python -m pytest tests/test_karat_diff_commission_one_writer.py -v
"""
import inspect
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import Account, Invoice, JournalEntry, JournalEntryLine, Settings, Supplier, db


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


def _auto_post(on):
    row = Settings.query.first() or Settings()
    row.auto_post_invoices = on
    db.session.add(row)
    db.session.flush()


@pytest.fixture
def supplier():
    """As in production (test_supplier_purchase_gold_follows_its_entry.pworld): the
    display stock (1300) keeps its weight on a memo account."""
    from party_account_service import ensure_supplier_accounts
    stock = Account.query.filter_by(account_number='1300').one()
    if not stock.memo_account_id:
        memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name=f'مخزون معروض وزني {_uid()}',
                       type='Asset', tracks_weight=True)
        db.session.add(memo)
        db.session.flush()
        stock.memo_account_id = memo.id
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _create(headers, supplier, *, earn=0.0, pay=0.0):
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=headers, json={
        'invoice_type': 'شراء', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': 1000.0,
        'karat_diff_earn_total': earn, 'karat_diff_pay_total': pay,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1, 'price': 1000.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    return resp.get_json()['id']


def _commissions(invoice_id):
    """{(account number, debit, credit)} of the invoice's posted commission entries, and how many entries."""
    revenue, expense = (Account.query.filter_by(account_number=n).first() for n in ('4110', '5240'))
    ids = {a.id for a in (revenue, expense) if a}
    entries = (JournalEntry.query.join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
               .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                       JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False),
                       JournalEntryLine.account_id.in_(ids or {-1})).distinct().all())
    lines = {(db.session.get(Account, l.account_id).account_number, round(float(l.cash_debit or 0), 2),
              round(float(l.cash_credit or 0), 2))
             for e in entries for l in e.lines if not l.is_deleted}
    return len(entries), lines


def test_a_purchase_posted_at_creation_carries_its_commission(auth_headers, supplier):
    _auto_post(True)
    invoice_id = _create(auth_headers, supplier, earn=307.37)
    assert db.session.get(Invoice, invoice_id).is_posted, 'posted at creation, as production posts'
    n, lines = _commissions(invoice_id)
    supplier_number = db.session.get(Account, supplier.account_id).account_number
    assert n == 1, 'one commission entry -- not none (3020), not two'
    assert lines == {(supplier_number, 307.37, 0.0), ('4110', 0.0, 307.37)}


def test_a_purchase_posted_later_carries_it_once(auth_headers, supplier):
    _auto_post(False)
    invoice_id = _create(auth_headers, supplier, pay=40.0)
    assert not db.session.get(Invoice, invoice_id).is_posted
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/invoices/post/{invoice_id}', headers=auth_headers, json={})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    n, lines = _commissions(invoice_id)
    supplier_number = db.session.get(Account, supplier.account_id).account_number
    assert n == 1
    assert lines == {('5240', 40.0, 0.0), (supplier_number, 0.0, 40.0)}


def test_a_supplier_without_an_account_refuses_the_posting(auth_headers, supplier):
    _auto_post(False)
    invoice_id = _create(auth_headers, supplier, earn=10.0)
    supplier.account_id = None
    db.session.flush()
    g.pop('current_user', None)
    resp = flask_app.test_client().post(f'/api/invoices/post/{invoice_id}', headers=auth_headers, json={})
    assert resp.status_code >= 400, 'refused -- not posted without its commission'
    db.session.expire_all()
    assert not db.session.get(Invoice, invoice_id).is_posted


def test_one_writer_for_the_commission():
    import posting_routes
    from routes import invoices
    assert not hasattr(posting_routes, '_create_and_post_karat_diff_entries_for_voucher')
    assert not hasattr(invoices, '_create_karat_diff_settlement_entries')
    source = inspect.getsource(posting_routes) + inspect.getsource(invoices)
    assert 'عمولة فرق العيار —' not in source, 'the entry is written in accounting/karat_diff_commission.py only'


# ── the second net: the nightly check ──

def test_the_nightly_check_names_a_posted_document_without_its_commission(supplier):
    from services.books_invariants import COMMISSION_NOT_WRITTEN, CHECKS
    from services.finding_kinds import KIND_INFO
    assert COMMISSION_NOT_WRITTEN in KIND_INFO, 'the screen says what it means'
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء', date=datetime(2026, 9, 15),
                  total=1000.0, status='unpaid', supplier_id=supplier.id, is_posted=True,
                  karat_diff_earn_total=307.37, karat_diff_pay_total=0.0)
    db.session.add(inv)
    db.session.flush()
    facts = {f.subject_key: f for f in CHECKS[COMMISSION_NOT_WRITTEN]()}
    assert facts[f'invoice:{inv.id}'].metric == pytest.approx(307.37)

    from accounting.karat_diff_commission import write_karat_diff_commission
    write_karat_diff_commission(inv, reference_type='invoice', label='t', by='t', now=datetime(2026, 10, 12))
    assert f'invoice:{inv.id}' not in {f.subject_key for f in CHECKS[COMMISSION_NOT_WRITTEN]()}


@pytest.mark.xfail(strict=True, reason='GOLD24K-001: the 24k settlement commission is written only by the later '
                                       'posting -- an invoice posted at creation carries none (no invoice used it '
                                       'by 12 Oct 2026); it has two writers too, the invoice\'s and the voucher\'s')
def test_a_24k_settlement_posted_at_creation_carries_its_commission(auth_headers, supplier):
    _auto_post(True)
    g.pop('current_user', None)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'invoice_type': 'شراء', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().isoformat(), 'total': 1000.0,
        'gold24k_settlement': True, 'gold24k_weight': 10.0, 'gold24k_commission_per_gram': 5.0,
        'gold24k_commission_total': 50.0,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1, 'price': 1000.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    invoice_id = resp.get_json()['id']
    assert JournalEntry.query.filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                                     JournalEntry.description.like('عمولة السداد بذهب صافي%')).count() == 1
