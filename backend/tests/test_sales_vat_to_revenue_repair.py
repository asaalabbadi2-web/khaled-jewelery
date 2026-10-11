"""Stage-4 item 22: the sales VAT of January-May 2026 is revenue (the owner, 11 Oct 2026).

«مبلغ ضريبة ما قبل 1/6 يجب أن يُحوَّل إلى حساب المبيعات، لأن ما كان بعد 1/5
المفروض أن يكون من بداية السنة»؛ «قيدًا لكل شهر». Sales carried 15 % VAT (24k
exempt) until the evening of 1 May and none after; the VAT stayed on 2300 --
and on 2210, where three April returns gave theirs back. One entry at each
month's end moves that month's VAT to the revenue account its own entry
credited (41 or 400; a return's, 420), so each month's revenue equals its
invoices. Nothing posted is edited.

Run:
    python -m pytest tests/test_sales_vat_to_revenue_repair.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, JournalEntry, JournalEntryLine, db
from services.repair.sales_vat_to_revenue import move_sales_vat_to_revenue
from services.sales_vat import VAT_TO_REVENUE


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


NOW = datetime(2034, 7, 1, 9, 0)


def _account(tag, kind, number=None):
    parent = None
    if kind == 'Revenue':                       # revenue is group 4, by the tree
        parent = Account.query.filter_by(account_number='4').first() or _account('الإيرادات', 'Root', '4')
    a = Account(account_number=number or f'9{uuid.uuid4().int % 10**7}', name=tag, type=kind,
                parent_id=parent.id if parent else None)
    db.session.add(a)
    db.session.flush()
    return a


def _invoice(kind, when, total, lines):
    inv = Invoice(invoice_type_id=uuid.uuid4().int % 900000 + 1, invoice_type=kind, date=when, total=total,
                  status='paid', amount_paid=total, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    je = JournalEntry(entry_number=f'JE-T-{uuid.uuid4().hex[:8]}', date=when, description=kind, entry_type='عادي',
                      reference_type='invoice', reference_id=inv.id, is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, amount in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description=kind,
                                        cash_debit=max(amount, 0), cash_credit=max(-amount, 0)))
    db.session.flush()
    return inv


@pytest.fixture
def books():
    from services.sales_vat import sales_vat_account_ids
    vat_ids = sales_vat_account_ids()
    vat = db.session.get(Account, sorted(vat_ids)[0]) if vat_ids else None
    if vat is None:
        from models import AccountingMapping
        vat = _account('ضريبة مبيعات اختبار', 'Liability')
        db.session.add(AccountingMapping(operation_type='بيع', account_type='vat_payable', account_id=vat.id,
                                         is_active=True))
        db.session.flush()
    fallback = Account.query.filter_by(account_number='2210').first() or _account('ضريبة مستحقة', 'Liability', '2210')
    b = {'vat': vat, 'fallback': fallback, 'activity': _account('إيرادات اختبار', 'Revenue'),
         'gold_new': _account('مبيعات ذهب جديد اختبار', 'Revenue'), 'returns': _account('مردودات اختبار', 'Revenue'),
         'customer': _account('عميل اختبار', 'Asset')}
    # March: one sale on the activity account, one split over two revenue accounts
    _invoice('بيع', datetime(2034, 3, 5), 1150.0, [(b['customer'], 1150), (b['activity'], -1000), (vat, -150)])
    _invoice('بيع', datetime(2034, 3, 9), 2300.0, [(b['customer'], 2300), (b['activity'], -1500),
                                                    (b['gold_new'], -500), (vat, -300)])
    # April: a sale, and a return giving its VAT back on 2210
    _invoice('بيع', datetime(2034, 4, 2), 575.0, [(b['customer'], 575), (b['gold_new'], -500), (vat, -75)])
    _invoice('مرتجع بيع', datetime(2034, 4, 20), 230.0, [(b['customer'], -230), (b['returns'], 200), (fallback, 30)])
    # June: after the cut -- stays
    _invoice('بيع', datetime(2034, 6, 3), 115.0, [(b['customer'], 115), (b['activity'], -100), (vat, -15)])
    return b


def _run(dry_run=False):
    return move_sales_vat_to_revenue(by='t', now=NOW, before=date(2034, 6, 1), since=date(2034, 1, 1),
                                     dry_run=dry_run)


def _cash(account, until=None):
    q = (JournalEntryLine.query.join(JournalEntry).filter(
        JournalEntryLine.account_id == account.id, JournalEntryLine.is_deleted.is_(False),
        JournalEntry.is_posted.is_(True), JournalEntry.date >= datetime(2034, 1, 1)))
    if until:
        q = q.filter(JournalEntry.date < until)
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in q), 2)


def test_each_months_vat_goes_to_the_revenue_its_entry_credited(books):
    b = books
    plan = _run(dry_run=True)
    assert [m['month'] for m in plan['months']] == ['2034-03', '2034-04']
    march, april = plan['months']
    assert march['lines'] == {b['vat'].account_number: pytest.approx(450),
                              b['activity'].account_number: pytest.approx(-150 - 225),
                              b['gold_new'].account_number: pytest.approx(-75)}, 'the split sale by its revenue'
    assert april['lines'] == {b['vat'].account_number: pytest.approx(75), b['gold_new'].account_number: pytest.approx(-75),
                              b['returns'].account_number: pytest.approx(30), '2210': pytest.approx(-30)}
    assert not JournalEntry.query.filter_by(reference_type=VAT_TO_REVENUE).filter(
        JournalEntry.date >= datetime(2034, 1, 1)).first(), 'a dry run writes nothing'

    done = _run()

    assert len(done['written']) == 2
    entries = JournalEntry.query.filter_by(reference_type=VAT_TO_REVENUE).filter(
        JournalEntry.date >= datetime(2034, 1, 1)).order_by(JournalEntry.date).all()
    assert [e.date for e in entries] == [datetime(2034, 3, 31, 23, 59, 59), datetime(2034, 4, 30, 23, 59, 59)]
    assert _cash(b['vat'], datetime(2034, 6, 1)) == pytest.approx(0), 'no VAT left owed before the cut'
    assert _cash(b['fallback']) == pytest.approx(0)
    assert _cash(b['vat']) == pytest.approx(-15), "June's VAT stays"
    revenue = -(_cash(b['activity'], datetime(2034, 4, 1)) + _cash(b['gold_new'], datetime(2034, 4, 1)))
    assert revenue == pytest.approx(1150 + 2300), "March's revenue is its invoices' totals"
    assert _cash(b['returns']) == pytest.approx(230), "April's return is its invoice's total"
    assert _run()['written'] == [], 'a second run writes nothing'


def test_the_gram_profit_counts_moved_vat_as_sales(books, auth_headers):
    """After the move, January-May's sales are their totals in the gram profit;
    VAT still owed (June here) stays out."""
    _run()
    body = flask_app.test_client().get('/api/reports/gram_profit?start_date=2034-03-01&end_date=2034-06-30',
                                       headers=auth_headers).get_json()
    assert body['total_sales_cash'] == pytest.approx(1150 + 2300 + 575 - 230 + 100)
