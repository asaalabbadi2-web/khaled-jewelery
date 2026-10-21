"""A supplier purchase's stones: counted as gold, or priced by the carat (ت4).

The owner (21 Oct 2026): gold is net in every screen, its stones beside it;
and at the supplier «بعض الأحجار تُحسب بسعر القيراط وبعضها تُحسب كذهب»:
  - stones counted as gold stay gold all the way -- in from the supplier at
    the standing weight as gold, out to the customer at the standing weight
    as gold (as the shop has always posted it);
  - stones priced by the carat leave the gold: the line's gold is its
    standing weight less their weight, and their value is owed in riyals --
    debit the role «مخزون الأحجار», credit the supplier -- with VAT as the
    wages take it (the owner's choice); followed by the piece from 2027.

The supplier purchase screen sent the standing weight as gold and showed the
net «بعد خصم الأحجار» only as a preview; the stones' value it collected the
server dropped. One rule now, on the server: a line's gold = its standing
weight - its priced stones; the supplier's gold is recomputed from the lines.

Run:
    python -m pytest tests/test_supplier_purchase_stones.py -v
"""
import uuid
from datetime import datetime

import pytest

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from app import app as flask_app
from models import (Account, AccountingMapping, InvoiceItem, JournalEntry, JournalEntryLine, SafeBox, Settings,
                    Supplier, db)

ROLE = 'stones_inventory'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


@pytest.fixture
def supplier(vat_mapped):
    """As in production: the display stock (1300) keeps its weight on a memo
    account with its safe; the supplier has its own accounts; invoices post at
    creation."""
    from party_account_service import ensure_supplier_accounts
    stock = Account.query.filter_by(account_number='1300').one()
    if not stock.memo_account_id:
        memo = Account(account_number=f'713{uuid.uuid4().int % 10**5:05d}', name=f'مخزون معروض وزني {_uid()}',
                       type='Asset', tracks_weight=True)
        db.session.add(memo)
        db.session.flush()
        stock.memo_account_id = memo.id
        db.session.add(SafeBox(name=f'المعروض {_uid()}', safe_type='gold', account_id=memo.id, is_active=True))
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    Settings.query.first().auto_post_invoices = True
    db.session.flush()
    return s


def _map_role():
    stones = Account(account_number=f'13{uuid.uuid4().int % 10**5:05d}', name='مخزون الأحجار', type='Asset')
    db.session.add(stones)
    db.session.flush()
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=ROLE,
                                     account_id=stones.id, is_active=True))
    db.session.flush()
    return stones


def _purchase(supplier, *, kind=None, stones=0.0, value=0.0, vat=False, standing=34.0):
    line = {'name': 'طقم أبيض', 'karat': 18, 'weight': standing, 'quantity': 1, 'price': 0,
            'wage_per_gram': 0, 'manufacturing_wage_per_gram': 0}
    if kind:
        line.update({'has_stones': True, 'stones_weight': stones, 'stones_kind': kind, 'stones_value': value})
    body = {'invoice_type': 'شراء', 'supplier_id': supplier.id, 'gold_type': 'new', 'vat_applied': vat,
            'date': datetime.now().date().isoformat(), 'items': [line],
            # the screen's own copy, from the standing weights -- not read when stones are priced
            'supplier_gold_lines': [{'karat': 18, 'weight': standing}]}
    if kind == 'priced':
        # the screen's totals carry the stones and their VAT, as it carries the wages
        settings = Settings.query.first()
        rate = float(settings.tax_rate or 0) if (vat and settings.tax_enabled is not False) else 0.0
        body.update({'stones_subtotal': value, 'stones_tax_total': round(value * rate, 2)})
    return body


def _post(headers, body):
    from flask import g
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/invoices', json=body, headers=headers)


def _entry_lines(invoice_id):
    je = JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id).first()
    return JournalEntryLine.query.filter_by(journal_entry_id=je.id).all()


def _supplier_gold(supplier, invoice_id):
    twin = Account.query.get(supplier.account_id).memo_account_id
    return sum(float(l.credit_18k or 0) - float(l.debit_18k or 0)
               for l in _entry_lines(invoice_id) if l.account_id == twin)


def test_stones_counted_as_gold_stay_gold(auth_headers, supplier):
    resp = _post(auth_headers, _purchase(supplier, kind='as_gold', stones=6.7))
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    invoice_id = resp.get_json()['id']
    assert _supplier_gold(supplier, invoice_id) == pytest.approx(34.0)
    item = InvoiceItem.query.filter_by(invoice_id=invoice_id).one()
    assert (item.weight, item.stones_weight, item.stones_kind) == (pytest.approx(34.0), pytest.approx(6.7), 'as_gold')


def test_priced_stones_leave_the_gold_and_are_owed_in_riyals(auth_headers, supplier):
    stones_account = _map_role()
    resp = _post(auth_headers, _purchase(supplier, kind='priced', stones=6.7, value=2000.0))
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    invoice_id = resp.get_json()['id']
    assert _supplier_gold(supplier, invoice_id) == pytest.approx(27.3)
    item = InvoiceItem.query.filter_by(invoice_id=invoice_id).one()
    assert (item.weight, item.standing_weight, item.stones_weight, item.stones_kind, item.stones_value) == (
        pytest.approx(27.3), pytest.approx(34.0), pytest.approx(6.7), 'priced', pytest.approx(2000.0))
    lines = _entry_lines(invoice_id)
    assert sum(float(l.cash_debit or 0) for l in lines if l.account_id == stones_account.id) == pytest.approx(2000.0)
    assert sum(float(l.cash_credit or 0) - float(l.cash_debit or 0)
               for l in lines if l.account_id == supplier.account_id) == pytest.approx(2000.0)


def test_priced_stones_take_vat_as_the_wages_do(auth_headers, supplier):
    _map_role()
    settings = Settings.query.first()
    settings.tax_rate, settings.tax_enabled = 0.15, True
    db.session.flush()
    resp = _post(auth_headers, _purchase(supplier, kind='priced', stones=6.7, value=2000.0, vat=True))
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    lines = _entry_lines(resp.get_json()['id'])
    rate = float(Settings.query.first().tax_rate or 0)
    assert sum(float(l.cash_credit or 0) - float(l.cash_debit or 0)
               for l in lines if l.account_id == supplier.account_id) == pytest.approx(round(2000.0 * (1 + rate), 2))


def test_priced_stones_with_the_role_unmapped_are_refused_saying_where(auth_headers, supplier):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    resp = _post(auth_headers, _purchase(supplier, kind='priced', stones=6.7, value=2000.0))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']


@pytest.mark.parametrize('stones, value, error', [
    (34.0, 2000.0, 'stones_heavier_than_line'),     # no gold left
    (6.7, 0.0, 'priced_stones_need_value'),
    (6.7, 2000.0, None),
])
def test_a_priced_stones_line_is_checked(auth_headers, supplier, stones, value, error):
    _map_role()
    body = _purchase(supplier, kind='priced', stones=stones, value=value)
    resp = _post(auth_headers, body)
    if error is None:
        assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
        return
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == error


def test_totals_that_do_not_carry_the_stones_are_refused(auth_headers, supplier):
    _map_role()
    body = _purchase(supplier, kind='priced', stones=6.7, value=2000.0)
    body['stones_subtotal'] = 0.0
    resp = _post(auth_headers, body)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'stones_totals_mismatch'


def test_an_unknown_stones_kind_is_refused(auth_headers, supplier):
    resp = _post(auth_headers, _purchase(supplier, kind='diamonds', stones=1.0, value=10.0))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_stones_kind'


def test_a_supplier_return_of_priced_stones_is_refused_until_it_is_built(auth_headers, supplier):
    body = _purchase(supplier, kind='priced', stones=6.7, value=2000.0)
    body['invoice_type'] = 'مرتجع شراء (مورد)'
    resp = _post(auth_headers, body)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'priced_stones_return_not_built'


def test_a_return_of_a_line_with_priced_stones_is_refused_until_it_is_built(auth_headers, supplier):
    """The return screen loads its original's lines without their stones: the
    gold would come back and their riyals stay owed -- refused by the original."""
    _map_role()
    bought = _post(auth_headers, _purchase(supplier, kind='priced', stones=6.7, value=2000.0))
    assert bought.status_code in (200, 201), bought.get_data(as_text=True)[:400]
    original = bought.get_json()['id']
    original_item = InvoiceItem.query.filter_by(invoice_id=original).one()
    resp = _post(auth_headers, {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': supplier.id, 'gold_type': 'new',
        'date': datetime.now().date().isoformat(), 'original_invoice_id': original,
        'items': [{'name': 'طقم أبيض', 'karat': 18, 'weight': 27.3, 'quantity': 1, 'price': 0,
                   'original_invoice_item_id': original_item.id}]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:400]
    assert resp.get_json()['error'] == 'priced_stones_return_not_built'
