"""An office's statement says the gold it holds for us (ADR-052; the owner, 9 Nov 2026).

The office's statement read its supplier account and its weight twin: the
trade -- what it is owed, what it owes, in cash and in gold. Our gold it holds
is its deposit («ذهب مودع لدى ...», ADR-052), an asset of ours as a bank
balance is: it was not on the statement at all. Now the statement reads both
-- one more column, «ذهبنا عنده»:

- an entry that has a row already (a reservation executed, the move into the
  deposit) carries its deposit movement on that row;
- an entry with no line on the office's accounts (the deposit to the
  showroom, a supplier paid from it) has a row of its own, the trade's
  running balances as they were;
- each row the custody's running balance; the statement its closing, by karat.

A supplier with no deposit: no custody, nothing else changed.

Run:
    python -m pytest tests/test_office_statement_custody.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import JournalEntry, SafeBox, Supplier, db
from services.repair.office_gold_deposits import REFERENCE, make_deposits
from tests.test_office_gold_deposits import NOW, _account, _post, office, parent  # noqa: F401


@pytest.fixture(autouse=True)
def rollback_after_each(db_fence):
    yield


def _statement(headers, supplier_id):
    g.pop('current_user', None)
    r = flask_app.test_client().get(f'/api/suppliers/{supplier_id}/statement', headers=headers)
    assert r.status_code == 200, r.get_data(as_text=True)[:300]
    return r.get_json()


def _deposit(office):
    make_deposits(by='owner', now=NOW)
    db.session.expire_all()
    return db.session.get(Supplier, office['supplier'].id).default_safe_box


def test_the_move_into_the_deposit_is_one_row_with_its_custody(auth_headers, office):
    deposit = _deposit(office)
    body = _statement(auth_headers, office['supplier'].id)
    move = JournalEntry.query.filter_by(reference_type=REFERENCE, reference_id=office['office'].id).one()
    rows = [l for l in body['lines'] if l['journal_entry_id'] == move.id]
    assert len(rows) == 1, 'one row for the entry: the trade and the custody side by side'
    assert rows[0]['custody_by_karat']['21k'] == 396.6 and rows[0]['running_custody_by_karat']['21k'] == 396.6
    custody = body['custody']
    assert (custody['safe_box_id'], custody['closing_by_karat']['21k']) == (deposit.id, 396.6)
    assert custody['name'] == deposit.name


def test_a_deposit_movement_with_no_trade_line_is_its_own_row(auth_headers, office):
    deposit = _deposit(office)
    acc = _account('7130', 'معروض', 'Asset', weight=True)
    showroom = SafeBox(name=f'معروض {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id, is_active=True,
                       stock_location='showroom')
    db.session.add(showroom)
    db.session.flush()
    g.pop('current_user', None)
    r = flask_app.test_client().post('/api/safe-boxes/transfer-voucher', headers=auth_headers, json={
        'from_safe_box_id': deposit.id, 'to_safe_box_id': showroom.id, 'weights': {'21k': 100.0}})
    assert r.status_code == 201, r.get_data(as_text=True)[:300]
    body = _statement(auth_headers, office['supplier'].id)
    last = body['lines'][-1]
    assert last['custody_by_karat']['21k'] == -100.0 and last['running_custody_by_karat']['21k'] == 296.6
    assert (last['cash_debit'], last['cash_credit'], last['gold_debit'], last['gold_credit']) == (0, 0, 0, 0), \
        'the trade did not move'
    before = body['lines'][-2]
    assert (last['running_cash_balance'], last['running_gold_balance']) == \
           (before['running_cash_balance'], before['running_gold_balance']), 'its running balances as they were'
    assert body['custody']['closing_by_karat']['21k'] == 296.6
    assert body['closing_balance_gold_details'] == _statement_without_custody_closing(body)


def _statement_without_custody_closing(body):
    """The trade's closing, recomputed from its own lines: the custody rows add nothing to it."""
    totals = {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
    for k in totals:
        totals[k] = round(float(body['opening_balance_gold_details'].get(k) or 0.0) + sum(
            float(l.get(f'debit_{k}') or 0) - float(l.get(f'credit_{k}') or 0) for l in body['lines']), 6)
    return {k: pytest.approx(v) for k, v in totals.items()}


def test_a_supplier_with_no_deposit_has_no_custody(auth_headers):
    cash = _account('21', f'مورد {uuid.uuid4().hex[:6]}', 'Liability', weight=False)
    supplier = Supplier(supplier_code=f'SNC-{uuid.uuid4().hex[:6]}', name='مورد بلا وديعة', account_id=cash.id)
    db.session.add(supplier)
    db.session.flush()
    _post(cash, cash_credit=1000.0)
    body = _statement(auth_headers, supplier.id)
    assert body.get('custody') is None
    assert all('custody_by_karat' not in l for l in body['lines'])
