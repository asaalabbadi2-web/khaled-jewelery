"""A return reverses its original invoice's VAT as posted (ADR-043, phase 3; rule 3).

A sale return took its VAT from what the screen sent -- else the return's
total_tax, else the original's total_tax, which reads 15/115 of the whole total
and disagrees with the posting on 91 invoices of January-April 2026 (24k is
exempt). With sales VAT off since May, the screen sends none: a return of a
taxed sale would have reversed no VAT and taken the whole refund off revenue.

Now the VAT a return reverses is read from its original:

    the original's VAT still owed (its posted entries; a month moved to revenue
    -- stage-4 item 22 -- carries none)
    x the returned share of its taxable lines (an exempt karat is no part)
    capped by what earlier returns have not reversed yet

and a return that carries VAT with no original to read it from is refused.

Run:
    python -m pytest tests/test_return_reverses_its_original_vat.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Invoice, InvoiceItem, JournalEntry, JournalEntryLine, Settings, db
from tests.retraction_world import _payload, world  # noqa: F401 (fixture)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture(autouse=True)
def _vat(vat_mapped):
    yield


def _sales_vat(on):
    row = Settings.query.first() or Settings()
    row.tax_enabled, row.tax_rate, row.auto_post_invoices, row.sales_vat_enabled = True, 0.15, True, on
    db.session.add(row)
    db.session.flush()


def _post(headers, payload):
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def _taxed_sale(headers, world):
    """2 g of 21k for 1,150.00, of which 150.00 VAT -- paid; VAT on, then off (as since May)."""
    _sales_vat(True)
    payload = _payload(world, 'sale_on_credit', held=False)
    payload.update({'total': 1150.0, 'total_tax': 150.0, 'total_cost': 0.0, 'amount_paid': 1150.0,
                    'payments': [{'payment_method_id': world['pm'].id, 'amount': 1150.0}]})
    payload['items'][0].update({'price': 1150.0, 'net': 1000.0, 'selling_price': 1150.0, 'tax': 150.0})
    resp = _post(headers, payload)
    assert resp.status_code == 201, resp.get_json()
    _sales_vat(False)
    return resp.get_json()


def _return(world, sale, *, total, weight, tax=0.0, original=True):
    item = sale['items'][0]
    payload = {
        'invoice_type': 'مرتجع بيع', 'customer_id': world['customer'].id, 'gold_type': 'new',
        'branch_id': sale.get('branch_id'), 'date': sale['date'], 'total': total, 'total_weight': weight,
        'total_tax': tax, 'amount_paid': total,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': total}],
        'items': [{'name': item['name'], 'karat': item['karat'], 'weight': weight, 'quantity': 1,
                   'price': total, 'net': total - tax, 'wage': 0, 'tax': tax,
                   'original_invoice_item_id': item['id']}],
    }
    if original:
        payload['original_invoice_id'] = sale['id']
    return payload


def _vat_reversed(invoice_id):
    vat = Account.query.filter_by(account_number='2300').one()
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in
                     JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                     .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                             JournalEntryLine.account_id == vat.id, JournalEntryLine.is_deleted.is_(False))), 2)


def test_a_whole_return_reverses_the_vat_its_sale_posted_though_the_screen_sends_none(auth_headers, world):
    sale = _taxed_sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, total=1150.0, weight=2.0, tax=0.0))
    assert resp.status_code == 201, resp.get_json()
    assert _vat_reversed(resp.get_json()['id']) == 150.0


def test_the_screens_vat_does_not_decide(auth_headers, world):
    sale = _taxed_sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, total=1150.0, weight=2.0, tax=172.5))
    assert resp.status_code == 201, resp.get_json()
    assert _vat_reversed(resp.get_json()['id']) == 150.0


def test_partial_returns_share_the_vat_and_never_exceed_it(auth_headers, world):
    sale = _taxed_sale(auth_headers, world)
    first = _post(auth_headers, _return(world, sale, total=575.0, weight=1.0))
    second = _post(auth_headers, _return(world, sale, total=575.0, weight=1.0))
    assert first.status_code == 201 and second.status_code == 201, (first.get_json(), second.get_json())
    assert _vat_reversed(first.get_json()['id']) == 75.0
    assert _vat_reversed(second.get_json()['id']) == 75.0


def test_a_return_carrying_vat_with_no_original_is_refused(auth_headers, world):
    sale = _taxed_sale(auth_headers, world)
    resp = _post(auth_headers, _return(world, sale, total=1150.0, weight=2.0, tax=150.0, original=False))
    assert resp.status_code == 400
    assert 'original_invoice_id' in str(resp.get_json()), 'a return names its original before anything else'


# ── the rule itself, on books built by hand ──────────────────────────────────

def _invoice(kind, lines, when=datetime(2033, 3, 5)):
    inv = Invoice(invoice_type_id=uuid.uuid4().int % 900000 + 1, invoice_type=kind, date=when,
                  total=sum(p for _, _, p in lines), status='paid', is_posted=True)
    db.session.add(inv)
    db.session.flush()
    for karat, weight, price in lines:
        db.session.add(InvoiceItem(invoice_id=inv.id, name='سطر', quantity=1, karat=karat, weight=weight, price=price))
    db.session.flush()
    return inv


def _posted_vat(inv, amount):
    vat = Account.query.filter_by(account_number='2300').one()
    other = Account(account_number=f'9{uuid.uuid4().int % 10**7}', name='مقابل', type='Asset')
    db.session.add(other)
    db.session.flush()
    je = JournalEntry(entry_number=f'JE-R-{uuid.uuid4().hex[:8]}', date=inv.date, description='بيع',
                      entry_type='عادي', reference_type='invoice', reference_id=inv.id, is_posted=True,
                      is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add_all([JournalEntryLine(journal_entry_id=je.id, account_id=vat.id, cash_credit=amount),
                        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, cash_debit=amount)])
    db.session.flush()


def test_an_exempt_karat_is_no_part_of_the_vat():
    from services.return_vat import vat_to_reverse
    sale = _invoice('بيع', [(21, 2.0, 1150.0), (24, 3.0, 1800.0)])
    _posted_vat(sale, 150.0)
    only_24 = _invoice('مرتجع بيع', [(24, 3.0, 1800.0)])
    only_21 = _invoice('مرتجع بيع', [(21, 2.0, 1150.0)])
    assert vat_to_reverse(only_24, sale, 'output', sent=0.0) == 0.0
    assert vat_to_reverse(only_21, sale, 'output', sent=0.0) == 150.0


def test_a_sale_whose_months_vat_was_moved_to_revenue_has_none_to_reverse():
    from services.return_vat import vat_to_reverse
    from services.sales_vat import VAT_TO_REVENUE
    sale = _invoice('بيع', [(21, 2.0, 1150.0)])
    _posted_vat(sale, 150.0)
    db.session.add(JournalEntry(entry_number=f'COR-T-{uuid.uuid4().hex[:6]}', date=datetime(2033, 3, 31, 23, 59, 59),
                                description='تحويل', reference_type=VAT_TO_REVENUE, reference_number='2033-03',
                                is_posted=True, is_draft=False, created_by='t'))
    db.session.flush()
    whole = _invoice('مرتجع بيع', [(21, 2.0, 1150.0)])
    assert vat_to_reverse(whole, sale, 'output', sent=0.0) == 0.0
