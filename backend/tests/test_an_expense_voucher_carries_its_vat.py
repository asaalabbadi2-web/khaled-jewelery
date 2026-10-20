"""An expense paid with a tax invoice carries its VAT (the owner, 20 Oct 2026).

«هناك مصروفات عليها ضريبة مستردة نريد آلية لتتبعها ضمن السند». On the 17 Oct
copy no expense voucher touched 1400 «ضريبة المدخلات»: packaging (39,383.75),
electricity (12,176.96) and the rest were posted whole, their VAT an expense,
never claimed; input VAT came from purchase invoices alone (22,494.62).

The owner's rules:
  - offered on operating expenses (52 «مصاريف تشغيلية») -- a payment voucher
    to «آخر» on one of its accounts; nothing else carries it;
  - the VAT is what the tax invoice says, suggested at the rate and corrected
    by hand -- never more than the rate's share of what was paid;
  - recorded only with its tax invoice: the supplier's name and VAT number
    (15 digits, 3 first and last), the invoice's number and date;
  - its account is the server's (ADR-043 rule 1, services/vat_policy): 1400
    while input VAT is recovered, else «غير القابلة للاسترداد».
The expense line is what was paid less its VAT; the VAT a line of its own;
the invoice kept on the voucher, replaced with it on an edit.

Run:
    python -m pytest tests/test_an_expense_voucher_carries_its_vat.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from app import app as flask_app
from models import Account, SafeBox, VatPolicyPeriod, Voucher, VoucherExpenseVat, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number, name, kind, parent=None):
    acc = Account(account_number=number, name=name, type=kind, transaction_type='cash',
                  parent_id=parent.id if parent else None)
    db.session.add(acc)
    db.session.flush()
    return acc


@pytest.fixture
def books(vat_mapped):
    """A cash safe; an operating expense under 52; an expense that is not one
    (a purchase under 51)."""
    from tests.voucher_world import auto_post
    auto_post(True)
    tag = uuid.uuid4().hex[:5]
    cash = _account(f'11{uuid.uuid4().int % 10**6:06d}', f'صندوق {tag}', 'Asset')
    db.session.add(SafeBox(name=f'صندوق {tag}', safe_type='cash', account_id=cash.id, is_active=True))
    operating = Account.query.filter_by(account_number='52').one()
    cost_of_sales = Account.query.filter_by(account_number='51').one()
    electricity = _account(f'52{uuid.uuid4().int % 10**5:05d}', f'كهرباء {tag}', 'Expense', operating)
    purchase = _account(f'51{uuid.uuid4().int % 10**5:05d}', f'مشتريات {tag}', 'Expense', cost_of_sales)
    db.session.flush()
    return {'cash': cash.id, 'electricity': electricity.id, 'purchase': purchase.id}


INVOICE = {'supplier_name': 'شركة الكهرباء', 'supplier_tax_number': '300000000000003',
           'invoice_number': 'F-1009', 'invoice_date': '2026-10-19'}


def _expense(b, *, account='electricity', paid=115.0, vat=15.0, invoice=None, voucher_type='payment',
             party_type='other'):
    body = {'voucher_type': voucher_type, 'date': datetime(2026, 10, 20).isoformat(), 'party_type': party_type,
            'account_lines': [
                {'account_id': b[account], 'line_type': 'debit', 'amount_type': 'cash', 'amount': paid},
                {'account_id': b['cash'], 'line_type': 'credit', 'amount_type': 'cash', 'amount': paid}]}
    if vat is not None:
        body['expense_vat'] = {'amount': vat, **(INVOICE if invoice is None else invoice)}
    return body


def _post(headers, body):
    return flask_app.test_client().post('/api/vouchers', headers=headers, json=body)


def _lines(voucher_id):
    db.session.expire_all()
    v = db.session.get(Voucher, voucher_id)
    return sorted((ln.line_type, Account.query.get(ln.account_id).account_number, round(ln.amount, 2))
                  for ln in v.account_lines.all())


def test_its_vat_is_a_line_of_its_own_on_input_vat_and_the_expense_is_what_is_left(auth_headers, books):
    resp = _post(auth_headers, _expense(books))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['id']
    electricity = Account.query.get(books['electricity']).account_number
    cash = Account.query.get(books['cash']).account_number
    assert _lines(vid) == sorted([('debit', electricity, 100.0), ('debit', '1400', 15.0), ('credit', cash, 115.0)])
    row = VoucherExpenseVat.query.filter_by(voucher_id=vid).one()
    assert (row.amount, row.recoverable, row.supplier_tax_number, row.invoice_number) == \
        (15.0, True, '300000000000003', 'F-1009')
    assert row.invoice_date == date(2026, 10, 19)


def test_the_voucher_says_its_invoice(auth_headers, books):
    vid = _post(auth_headers, _expense(books)).get_json()['id']
    got = flask_app.test_client().get(f'/api/vouchers/{vid}', headers=auth_headers).get_json()
    assert got['expense_vat']['amount'] == 15.0
    assert got['expense_vat']['supplier_name'] == 'شركة الكهرباء'
    assert got['expense_vat']['recoverable'] is True


def test_not_recovered_its_vat_is_the_non_recoverable_expense(auth_headers, books):
    VatPolicyPeriod.query.delete()
    db.session.add(VatPolicyPeriod(effective_from=date(2000, 1, 1), input_vat_recoverable=False,
                                   sales_vat_charged=False, created_by='t'))
    db.session.flush()
    from services.vat_policy import non_recoverable_account_id
    vid = _post(auth_headers, _expense(books)).get_json()['id']
    vat_line = [ln for ln in _lines(vid) if ln[2] == 15.0]
    assert vat_line == [('debit', Account.query.get(non_recoverable_account_id()).account_number, 15.0)]
    assert VoucherExpenseVat.query.filter_by(voucher_id=vid).one().recoverable is False


@pytest.mark.parametrize('vat, ok', [(15.0, True), (15.01, True), (15.03, False), (20.0, False)])
def test_never_more_than_the_rates_share_of_what_was_paid(auth_headers, books, vat, ok):
    resp = _post(auth_headers, _expense(books, vat=vat))
    if ok:
        assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    else:
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'expense_vat_above_rate'


@pytest.mark.parametrize('missing', ['supplier_name', 'supplier_tax_number', 'invoice_number', 'invoice_date'])
def test_recorded_only_with_its_tax_invoice(auth_headers, books, missing):
    before = Voucher.query.count()
    resp = _post(auth_headers, _expense(books, invoice={**INVOICE, missing: ''}))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'expense_vat_needs_tax_invoice'
    assert Voucher.query.count() == before


@pytest.mark.parametrize('number', ['30000000000000', '100000000000003', '30000000000000A', '300000000000001'])
def test_a_vat_number_is_fifteen_digits_three_first_and_last(auth_headers, books, number):
    resp = _post(auth_headers, _expense(books, invoice={**INVOICE, 'supplier_tax_number': number}))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'expense_vat_bad_tax_number'


@pytest.mark.parametrize('case', ['a_purchase', 'a_receipt', 'a_supplier'])
def test_only_an_operating_expense_carries_it(auth_headers, books, case):
    body = {'a_purchase': _expense(books, account='purchase'),
            'a_receipt': _expense(books, voucher_type='receipt'),
            'a_supplier': _expense(books, party_type='supplier')}[case]
    resp = _post(auth_headers, body)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'expense_vat_operating_expenses_only'


def test_an_expense_without_it_is_posted_whole(auth_headers, books):
    vid = _post(auth_headers, _expense(books, vat=None)).get_json()['id']
    assert ('debit', Account.query.get(books['electricity']).account_number, 115.0) in _lines(vid)
    assert VoucherExpenseVat.query.filter_by(voucher_id=vid).count() == 0


def test_an_edit_replaces_its_invoice(auth_headers, books):
    from tests.voucher_world import auto_post
    auto_post(False)
    vid = _post(auth_headers, _expense(books)).get_json()['id']
    resp = flask_app.test_client().put(f'/api/vouchers/{vid}', headers=auth_headers,
                                       json=_expense(books, vat=10.0, invoice={**INVOICE, 'invoice_number': 'F-2'}))
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    rows = VoucherExpenseVat.query.filter_by(voucher_id=vid).all()
    assert [(r.amount, r.invoice_number) for r in rows] == [(10.0, 'F-2')]
    assert ('debit', '1400', 10.0) in _lines(vid)
