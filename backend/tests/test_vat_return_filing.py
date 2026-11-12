"""A VAT return closes a period's output and input VAT into what is owed to the authority (ADR-043, phase 6; rule 5).

The owner (11 Oct 2026): the net after offsetting input against output is
owed to the authority -- settled from that account, never through an expense:
the VAT was never revenue. Filing a period writes one entry at its last day:

    debit  output VAT (2300)        what the period credited it
    credit input VAT (1400, 1410)   what the period debited them
    credit / debit 2301             the net -- owed to the authority, or due back

recorded as a vat_return. Periods do not overlap; a period not over is not
filed; a preview writes nothing. Paying it is a payment voucher on 2301 from
the bank (a refund, a receipt) -- no new code, and no expense.

Run:
    python -m pytest tests/test_vat_return_filing.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, AccountingMapping, JournalEntry, JournalEntryLine, db

NOW = datetime(2034, 3, 5, 10, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def books(vat_mapped):
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    commission_vat = Account.query.filter_by(account_number='1410').first()
    if commission_vat is None:
        commission_vat = Account(account_number='1410', name='ضريبة عمولات نقاط البيع', type='Asset')
        db.session.add(commission_vat)
        db.session.flush()
    AccountingMapping.query.filter_by(account_type='commission_vat').update({'is_active': False})
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='commission_vat',
                                     account_id=commission_vat.id, is_active=True))
    if not Account.query.filter_by(account_number='230').first():
        db.session.add(Account(account_number='230', name='ضريبة القيمة المضافة المستحقة', type='Liability'))
    cash = Account(account_number=f'9{uuid.uuid4().int % 10**7}', name='بنك اختبار', type='Asset')
    db.session.add(cash)
    db.session.flush()
    return {'output': Account.query.filter_by(account_number='2300').one(),
            'input': Account.query.filter_by(account_number='1400').one(),
            'commission': commission_vat, 'cash': cash}


def _entry(day, lines):
    je = JournalEntry(entry_number=f'JE-V-{uuid.uuid4().hex[:8]}', date=day, description='اختبار',
                      entry_type='عادي', reference_type='invoice', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, amount in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='اختبار',
                                        cash_debit=max(amount, 0), cash_credit=max(-amount, 0)))
    db.session.flush()


def _january(b, *, output=1500.0, input_=300.0, commission=20.0, year=2034):
    _entry(datetime(year, 1, 10), [(b['cash'], output), (b['output'], -output)])
    _entry(datetime(year, 1, 12), [(b['input'], input_), (b['cash'], -input_)])
    _entry(datetime(year, 1, 20), [(b['commission'], commission), (b['cash'], -commission)])
    _entry(datetime(year, 2, 3), [(b['cash'], 99.0), (b['output'], -99.0)])       # February: not January's


def _moved(account, until=None):
    q = (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(JournalEntryLine.account_id == account.id, JournalEntryLine.is_deleted.is_(False),
                 JournalEntry.is_posted.is_(True), JournalEntry.date >= datetime(2034, 1, 1)))
    if until:
        q = q.filter(JournalEntry.date < until)
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in q), 2)


def test_filing_a_period_closes_its_vat_into_what_is_owed(books):
    from services.vat_return import file_vat_return, settlement_account_id
    b = books
    _january(b)
    preview = file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW, dry_run=True)
    assert (preview['output_vat'], preview['input_vat'], preview['net']) == (1500.0, 320.0, 1180.0)
    assert not JournalEntry.query.filter_by(reference_type='vat_return').filter(
        JournalEntry.date >= datetime(2034, 1, 1)).first(), 'a preview writes nothing'

    filed = file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)

    feb = datetime(2034, 2, 1)
    assert _moved(b['output'], feb) == 0 and _moved(b['input'], feb) == 0 and _moved(b['commission'], feb) == 0
    owed = db.session.get(Account, settlement_account_id())
    # Made once under the mapped parent (230 on production, where 2301 is mapped):
    # its place, not a number written here (CHART-002 release 5b).
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    assert owed.parent_id == require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'vat_settlement_parent')
    assert _moved(owed) == -1180.0, 'owed to the authority'
    assert _moved(b['output']) == -99.0, "February's VAT is February's"
    assert filed['entry_number']


def test_more_input_than_output_is_due_back(books):
    from services.vat_return import file_vat_return, settlement_account_id
    _january(books, output=100.0, input_=300.0, commission=0.0)
    filed = file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)
    assert filed['net'] == -200.0
    assert _moved(db.session.get(Account, settlement_account_id())) == 200.0, 'due back from the authority'


def test_periods_do_not_overlap_and_are_over(books):
    from services.vat_return import VatReturnRefused, file_vat_return
    _january(books)
    file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)
    with pytest.raises(VatReturnRefused):
        file_vat_return(start=date(2034, 1, 15), end=date(2034, 2, 28), by='t', now=NOW)
    with pytest.raises(VatReturnRefused):
        file_vat_return(start=date(2034, 3, 1), end=date(2034, 3, 31), by='t', now=NOW)     # not over on 5 March


def test_the_next_period_does_not_count_the_filing_itself(books):
    from services.vat_return import file_vat_return
    _january(books)
    file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)
    february = file_vat_return(start=date(2034, 2, 1), end=date(2034, 2, 28), by='t', now=NOW, dry_run=True)
    assert (february['output_vat'], february['input_vat']) == (99.0, 0.0)


def test_the_routes(books, auth_headers):
    _january(books, year=2001)                     # a period long over, by the clock the routes read
    client = flask_app.test_client()
    body = {'start': '2001-01-01', 'end': '2001-01-31'}
    preview = client.post('/api/vat-returns/preview', headers=auth_headers, json=body)
    assert preview.status_code == 200 and preview.get_json()['net'] == 1180.0
    filed = client.post('/api/vat-returns', headers=auth_headers, json=body)
    assert filed.status_code == 201, filed.get_json()
    again = client.post('/api/vat-returns', headers=auth_headers, json=body)
    assert again.status_code == 409
    listed = client.get('/api/vat-returns', headers=auth_headers).get_json()
    assert any(r['start'] == '2001-01-01' and r['net'] == 1180.0 for r in listed)


def test_a_nil_return_files_its_period(books):
    from models import VatReturn
    from services.vat_return import VatReturnRefused, file_vat_return
    out = file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)
    assert out['net'] == 0 and out['entry_number'] is None
    assert VatReturn.query.filter_by(period_start=date(2034, 1, 1)).count() == 1
    with pytest.raises(VatReturnRefused):
        file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)


# ── as filed, while sales carry no VAT (ADR-089, the owner 12 Nov 2026) ──

@pytest.fixture
def untaxed(books):
    """Sales untaxed from 2034 on, and «ضريبة القيمة المضافة الغير قابلة للاسترداد» as production
    spells it, under the mapped parent -- the account the filing must find, not make again."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from models import VatPolicyPeriod
    db.session.add(VatPolicyPeriod(effective_from=date(2034, 1, 1), input_vat_recoverable=True,
                                   sales_vat_charged=False, created_by='t'))
    AccountingMapping.query.filter_by(account_type='vat_non_recoverable').update({'is_active': False})
    parent_id = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'vat_non_recoverable_parent')
    if not parent_id:
        parent = Account(account_number=f'9{uuid.uuid4().int % 10**7}', name='مصاريف اختبار', type='Expense')
        db.session.add(parent)
        db.session.flush()
        db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                         account_type='vat_non_recoverable_parent', account_id=parent.id,
                                         is_active=True))
        parent_id = parent.id
    for a in Account.query.filter(Account.name.in_(['ضريبة القيمة المضافة غير القابلة للاسترداد',
                                                    'ضريبة القيمة المضافة الغير قابلة للاسترداد'])).all():
        a.name = a.name + ' (قديم)'            # this test's own: the one it makes below
    expense = Account(account_number=f'9{uuid.uuid4().int % 10**7}', name='ضريبة القيمة المضافة الغير قابلة للاسترداد',
                      type='Expense', parent_id=parent_id)
    db.session.add(expense)
    db.session.flush()
    return {**books, 'expense': expense}


def test_untaxed_sales_are_filed_with_the_returns_output_and_what_the_books_lack_is_the_expense(untaxed):
    from models import VatReturn
    from services.vat_return import VatReturnRefused, file_vat_return, settlement_account_id
    b = untaxed
    _january(b, output=0.0, input_=300.0, commission=20.0)          # the books: no output, 320 of input
    with pytest.raises(VatReturnRefused) as refused:
        file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW)
    assert refused.value.code == 'OUTPUT_VAT_REQUIRED'

    filed = file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW,
                            filed_output_vat=1500, filed_input_vat=400)
    # the return's own: 1500 out, 400 in, 1100 owed; the books lacked 1500 of output and 80 of input
    assert (filed['output_vat'], filed['input_vat'], filed['net']) == (1500.0, 400.0, 1100.0)
    assert (filed['books_output_vat'], filed['books_input_vat'], filed['non_recoverable']) == (0.0, 320.0, 1420.0)
    assert _moved(b['expense']) == 1420.0, 'what the books lacked: an expense the weight profit reads'
    from services.vat_policy import NON_RECOVERABLE_NAMES
    assert Account.query.filter(Account.name.in_(NON_RECOVERABLE_NAMES)).count() == 1, \
        'production\'s «الغير» account found, none made'
    feb = datetime(2034, 2, 1)
    assert _moved(b['input'], feb) == 0 and _moved(b['commission'], feb) == 0
    assert _moved(db.session.get(Account, settlement_account_id())) == -1100.0
    record = VatReturn.query.filter_by(period_start=date(2034, 1, 1)).one()
    assert (record.output_vat, record.input_vat, record.net) == (1500.0, 400.0, 1100.0)


def test_input_the_books_lack_beyond_the_output_they_lack_is_refused(untaxed):
    from services.vat_return import VatReturnRefused, file_vat_return
    _january(untaxed, output=0.0, input_=300.0, commission=20.0)
    with pytest.raises(VatReturnRefused) as refused:            # lacking: 100 out, 180 in -- record it first
        file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW,
                        filed_output_vat=100, filed_input_vat=500)
    assert refused.value.code == 'INPUT_VAT_MISSING'
    with pytest.raises(VatReturnRefused) as refused:
        file_vat_return(start=date(2034, 1, 1), end=date(2034, 1, 31), by='t', now=NOW,
                        filed_output_vat=-1, filed_input_vat=0)
    assert refused.value.code == 'INVALID_FIGURE'


def test_the_routes_carry_the_returns_figures(untaxed, auth_headers):
    from models import VatPolicyPeriod
    db.session.add(VatPolicyPeriod(effective_from=date(2001, 1, 1), input_vat_recoverable=True,
                                   sales_vat_charged=False, created_by='t'))
    _january(untaxed, output=0.0, input_=300.0, commission=20.0, year=2001)
    client = flask_app.test_client()
    body = {'start': '2001-01-01', 'end': '2001-01-31'}
    preview = client.post('/api/vat-returns/preview', headers=auth_headers,
                          json={**body, 'filed_output_vat': 1500, 'filed_input_vat': 400}).get_json()
    assert (preview['net'], preview['non_recoverable']) == (1100.0, 1420.0)
    # last: a refusal rolls the request back, and the test fence does not hold (Flask-SQLAlchemy 3.1)
    refused = client.post('/api/vat-returns/preview', headers=auth_headers, json=body)
    assert refused.status_code == 400 and refused.get_json()['error'] == 'OUTPUT_VAT_REQUIRED'
