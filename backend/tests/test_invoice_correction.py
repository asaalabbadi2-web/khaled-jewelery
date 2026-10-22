"""«تصحيح فاتورة»: a posted line put right by the difference, in one document (ت-1).

The owner (22 Oct 2026, docs/plans/invoice-correction-study.md): 11 of 2026's
21 returns were corrections -- a karat, a weight or a price entered wrong --
each made by a whole return and a re-entry (3314's 1.5 g of 18k: four
documents). One document instead:

  - the line corrected IN PLACE -- the invoice says what happened;
  - ONE entry of the difference, dated the day: the line as posted out of the
    safe the gold is in now, the right lines in, against the purchases'
    weight side; a price's difference on the customer's account;
  - a record of what was and what is, why, who, when;
  - refused by name: no reason, an invoice not posted, a type not built yet
    (a sale, a supplier's), an invoice returned from, gold the safe does not
    hold, a line of another invoice;
  - the preview writes nothing; from the settings' day (ADR-042) a karat
    alone restates the gold at no value, a price at its difference, and the
    night says nothing.

Run:
    python -m pytest tests/test_invoice_correction.py -v
"""
from datetime import date

import pytest

from app import app as flask_app
from models import (Invoice, InvoiceCorrection, InvoiceItem, JournalEntry, JournalEntryLine, SafeBox, Settings,
                    db)
from tests.test_gold_bought_enters_its_stock import _purchase, world  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _correct(headers, invoice_id, body, *, preview=False):
    path = f'/api/invoices/{invoice_id}/corrections' + ('/preview' if preview else '')
    return flask_app.test_client().post(path, headers=headers, json=body)


def _bought(headers, w, grams=3.3, price=330.0):
    """Below the test database's live price, so it posts at once (3314's 1,400 scaled)."""
    invoice = _purchase(headers, w, grams=grams, price=price)
    return invoice, Invoice.query.get(invoice['id']).items[0]


def _grams(entry_id, account_id):
    out = {}
    for l in JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=account_id, is_deleted=False):
        for k in (18, 21, 22, 24):
            g = float(getattr(l, f'debit_{k}k') or 0) - float(getattr(l, f'credit_{k}k') or 0)
            if abs(g) > 1e-9:
                out[k] = round(out.get(k, 0.0) + g, 3)
    return {k: v for k, v in out.items() if abs(v) > 1e-9}


def test_3314_one_document_puts_the_karat_right(auth_headers, world):
    """3.3 g counted as 21k, 1.5 g of it 18k: one correction, no money."""
    invoice, line = _bought(auth_headers, world)
    custody = world['custody']
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح عيار', 'safe_box_id': SafeBox.query.filter_by(account_id=custody.id).one().id,
        'lines': [{'karat': 21, 'weight': 1.8, 'price': 180.0}, {'karat': 18, 'weight': 1.5, 'price': 150.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    correction = InvoiceCorrection.query.get(resp.get_json()['id'])
    entry = db.session.get(JournalEntry, correction.journal_entry_id)
    assert entry.is_posted and entry.reference_type == 'invoice_correction'
    assert _grams(entry.id, custody.id) == {21: -1.5, 18: 1.5}, 'the difference, in the custody'
    assert not any(float(l.cash_debit or 0) or float(l.cash_credit or 0)
                   for l in JournalEntryLine.query.filter_by(journal_entry_id=entry.id)), 'no money moves'
    items = InvoiceItem.query.filter_by(invoice_id=invoice['id']).order_by(InvoiceItem.id).all()
    assert [(int(i.karat), i.weight, i.net) for i in items] == [(21, 1.8, 180.0), (18, 1.5, 150.0)], 'in place'
    inv = Invoice.query.get(invoice['id'])
    assert (inv.total, inv.total_weight) == (pytest.approx(330.0), pytest.approx(3.3))
    assert correction.before['lines'][0]['karat'] == 21 and correction.before['lines'][0]['weight'] == 3.3
    assert [l['karat'] for l in correction.after['lines']] == [21, 18]
    assert correction.before['snapshot_schema_version'] == 1 and correction.reason == 'تصحيح عيار'


def test_a_price_put_right_moves_its_difference_on_the_customers_account(auth_headers, world):
    invoice, line = _bought(auth_headers, world, grams=2.2, price=220.0)
    custody_safe = SafeBox.query.filter_by(account_id=world['custody'].id).one()
    resp = _correct(auth_headers, invoice['id'], {'line_id': line.id, 'reason': 'سعر خاطئ',
                                                  'safe_box_id': custody_safe.id,
                                                  'lines': [{'karat': 21, 'weight': 2.2, 'price': 230.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    correction = InvoiceCorrection.query.get(resp.get_json()['id'])
    assert correction.cash_delta == pytest.approx(10.0)
    entry_lines = JournalEntryLine.query.filter_by(journal_entry_id=correction.journal_entry_id).all()
    assert sum(float(l.cash_debit or 0) for l in entry_lines) == pytest.approx(10.0)
    assert Invoice.query.get(invoice['id']).total == pytest.approx(230.0)
    assert _grams(correction.journal_entry_id, world['custody'].id) == {}, 'the same gold'


def test_the_gold_is_put_right_where_it_is_now(auth_headers, world):
    """The gold went on to another scrap safe: corrected there, no transfers."""
    from tests.test_melting_and_renewal_go_one_way import _holds, _safe
    invoice, line = _bought(auth_headers, world)
    elsewhere = _safe('scrap')
    _holds(elsewhere, 21, 3.3)
    resp = _correct(auth_headers, invoice['id'], {'line_id': line.id, 'reason': 'تصحيح عيار', 'safe_box_id': elsewhere.id,
                                                  'lines': [{'karat': 18, 'weight': 3.3, 'price': 330.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    correction = InvoiceCorrection.query.get(resp.get_json()['id'])
    assert _grams(correction.journal_entry_id, elsewhere.account_id) == {21: -3.3, 18: 3.3}


@pytest.mark.parametrize('change, error', [
    ({'reason': ''}, 'correction_reason_required'),
    ({'lines': [{'karat': 20, 'weight': 3.3, 'price': 330.0}]}, 'correction_karat_invalid'),
    ({'lines': [{'karat': 21, 'weight': 0, 'price': 330.0}]}, 'correction_weight_invalid'),
    ({'lines': []}, 'correction_lines_required'),
    ({'safe_box_id': None}, 'correction_safe_invalid'),
    ({'line_id': 0}, 'correction_line_not_found'),
])
def test_what_is_refused_says_why(auth_headers, world, change, error):
    invoice, line = _bought(auth_headers, world)
    body = {'line_id': line.id, 'reason': 'تصحيح', 'lines': [{'karat': 18, 'weight': 3.3, 'price': 330.0}],
            'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id, **change}
    resp = _correct(auth_headers, invoice['id'], body)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == error
    assert InvoiceCorrection.query.filter_by(invoice_id=invoice['id']).count() == 0


def test_gold_the_safe_does_not_hold_is_refused(auth_headers, world):
    from tests.test_melting_and_renewal_go_one_way import _safe
    invoice, line = _bought(auth_headers, world)
    empty = _safe('scrap')
    resp = _correct(auth_headers, invoice['id'], {'line_id': line.id, 'reason': 'تصحيح', 'safe_box_id': empty.id,
                                                  'lines': [{'karat': 18, 'weight': 3.3, 'price': 330.0}]})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'insufficient_balance'


def test_a_suppliers_invoice_is_not_built_yet(auth_headers, world):
    from datetime import datetime
    sale = Invoice(invoice_type='شراء', total=100.0, is_posted=True, invoice_type_id=987654, date=datetime(2026, 10, 22))
    db.session.add(sale)
    db.session.flush()
    resp = _correct(auth_headers, sale.id, {'line_id': 1, 'reason': 'تصحيح', 'safe_box_id': 1,
                                            'lines': [{'karat': 21, 'weight': 1, 'price': 1}]})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'correction_not_built_for_type'


def test_the_preview_says_the_entry_and_keeps_nothing(auth_headers, world):
    invoice, line = _bought(auth_headers, world)
    entries = JournalEntry.query.count()
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح عيار', 'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id,
        'lines': [{'karat': 21, 'weight': 1.8, 'price': 180.0}, {'karat': 18, 'weight': 1.5, 'price': 150.0}]},
        preview=True)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['preview'] is True
    shown = {(l['side'], l['amount_type'], l['amount'], l['karat']) for l in resp.get_json()['lines']}
    assert {('credit', 'gold', 3.3, 21), ('debit', 'gold', 1.8, 21), ('debit', 'gold', 1.5, 18)} <= shown, \
        'shown as the melting shows its entry: a side, an amount, a karat'
    db.session.expire_all()
    assert JournalEntry.query.count() == entries
    assert InvoiceCorrection.query.filter_by(invoice_id=invoice['id']).count() == 0
    assert [(int(i.karat), i.weight) for i in InvoiceItem.query.filter_by(invoice_id=invoice['id'])] == [(21, 3.3)]


def test_from_the_settings_day_a_karat_alone_restates_the_gold_and_the_night_says_nothing(auth_headers, world):
    from services.books_invariants import CHECKS, GOLD_COST_DRIFT, GOLD_MOVED_UNVALUED
    from tests.test_gold_bought_enters_its_stock import _square_the_scrap_pool, exchange  # noqa: F401
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    from models import Account, AccountingMapping
    acc = Account(account_number='5219777', name='فروق تبادل', type='Expense', transaction_type='cash')
    db.session.add(acc)
    db.session.flush()
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                     account_type='gold_exchange_difference', account_id=acc.id, is_active=True))
    Settings.query.first().gold_cost_from = date(2026, 1, 1)
    db.session.flush()
    _square_the_scrap_pool(weight=50.0, value=20000.0)
    invoice, line = _bought(auth_headers, world)

    def night():   # the test database holds others' entries too: what the correction changes is the witness
        drift = {f.subject_key: f.metric for f in CHECKS[GOLD_COST_DRIFT]()}
        return drift, {f.subject_key for f in CHECKS[GOLD_MOVED_UNVALUED]()}
    before = night()
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح عيار', 'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id,
        'lines': [{'karat': 21, 'weight': 1.8, 'price': 180.0}, {'karat': 18, 'weight': 1.5, 'price': 150.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    after = night()
    assert after[1] == before[1], 'the correction is no unvalued movement'
    assert after[0].keys() == before[0].keys() and all(
        after[0][k] == pytest.approx(before[0][k], abs=0.01) for k in after[0]), 'nor a drift'


def test_an_invoice_returned_from_is_refused_until_it_is_built(auth_headers, world):
    from datetime import datetime
    invoice, line = _bought(auth_headers, world)
    resp = flask_app.test_client().post('/api/invoices', headers=auth_headers, json={
        'customer_id': world['customer'].id, 'invoice_type': 'مرتجع شراء', 'gold_type': 'scrap',
        'original_invoice_id': invoice['id'], 'return_reason': 'عيب', 'date': datetime(2026, 10, 21, 13).isoformat(),
        'total': 100.0, 'total_weight': 1.0, 'total_tax': 0.0, 'total_cost': 100.0, 'amount_paid': 100.0,
        'payments': [{'payment_method_id': world['pm'].id, 'amount': 100.0}],
        'items': [{'original_invoice_item_id': line.id, 'name': 'كسر', 'karat': 21, 'weight': 1.0, 'quantity': 1,
                   'cost': 100.0, 'net': 100.0, 'tax': 0.0, 'price': 100.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح', 'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id,
        'lines': [{'karat': 18, 'weight': 3.3, 'price': 330.0}]})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'correction_after_return_not_built'


def test_a_scrap_line_in_another_karat_takes_that_karats_scrap_category(auth_headers, world):
    """Seen on the 21 Oct copy (3434): «كسر 21» corrected to 18k left the 18k
    line with no category; it is «كسر 18»."""
    from models import Category
    scrap21 = Category.query.filter_by(is_scrap=True, karat='21').first() or Category(
        name='كسر 21', karat='21', is_scrap=True, is_active=True)
    scrap18 = Category.query.filter_by(is_scrap=True, karat='18').first() or Category(
        name='كسر 18', karat='18', is_scrap=True, is_active=True)
    db.session.add_all([scrap21, scrap18])
    db.session.flush()
    invoice, line = _bought(auth_headers, world)
    line.category_id = scrap21.id
    db.session.flush()
    resp = _correct(auth_headers, invoice['id'], {
        'line_id': line.id, 'reason': 'تصحيح عيار', 'safe_box_id': SafeBox.query.filter_by(account_id=world['custody'].id).one().id,
        'lines': [{'karat': 21, 'weight': 1.8, 'price': 180.0}, {'karat': 18, 'weight': 1.5, 'price': 150.0}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    items = InvoiceItem.query.filter_by(invoice_id=invoice['id']).order_by(InvoiceItem.id).all()
    assert [(int(i.karat), i.category_id) for i in items] == [(21, scrap21.id), (18, scrap18.id)]


def test_the_list_says_its_corrections_and_the_safe_to_start_from(auth_headers, world):
    invoice, line = _bought(auth_headers, world)
    custody_safe = SafeBox.query.filter_by(account_id=world['custody'].id).one()
    listed = flask_app.test_client().get(f'/api/invoices/{invoice["id"]}/corrections', headers=auth_headers).get_json()
    assert listed == {'corrections': [], 'suggested_safe_box_id': custody_safe.id}
    _correct(auth_headers, invoice['id'], {'line_id': line.id, 'reason': 'تصحيح عيار', 'safe_box_id': custody_safe.id,
                                           'lines': [{'karat': 18, 'weight': 3.3, 'price': 330.0}]})
    listed = flask_app.test_client().get(f'/api/invoices/{invoice["id"]}/corrections', headers=auth_headers).get_json()
    assert [c['reason'] for c in listed['corrections']] == ['تصحيح عيار']
