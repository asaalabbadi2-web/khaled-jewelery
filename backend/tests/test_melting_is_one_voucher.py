"""A melting or a renewal is one voucher, its damage wage posted once (ADR-050).

The screen sent one request per karat line, the operation's damage wage with
each: three lines posted the wage three times, while its confirmation showed
it once. And a refused second line left the first posted -- a retry posted it
again. The law: the operation's lines travel together, are checked together
(a karat's lines summed against its balance), and post as one voucher or not
at all.

Run:
    python -m pytest tests/test_melting_is_one_voucher.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

import routes.system as system_routes
from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, Voucher, VoucherAccountLine, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(prefix, name, **kw):
    acc = Account(account_number=f'{prefix}{uuid.uuid4().int % 10**7:07d}', name=name, **kw)
    db.session.add(acc)
    db.session.flush()
    return acc


def _gold_safe(name):
    acc = _account('7', name, type='Asset', tracks_weight=True)
    box = SafeBox(name=f'{name} {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id, is_active=True)
    db.session.add(box)
    db.session.flush()
    return box


def _ledger(box, karat, grams):
    """The posted ledger says the safe holds *grams* of *karat*."""
    other = _account('8', 'مقابل', type='Asset', tracks_weight=True)
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 9, 1), description='t',
                      is_posted=True)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, **{f'debit_{karat}k': grams}),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, **{f'credit_{karat}k': grams}),
    ])
    db.session.flush()


@pytest.fixture
def capitalized_wages(monkeypatch):
    """Wages sit on an inventory account, so a melting writes the damaged wage off."""
    inventory = _account('9', 'مخزون أجور المصنعية', type='Asset')
    monkeypatch.setattr(system_routes, 'wages_are_capitalized', lambda mode: True)
    monkeypatch.setattr(system_routes, '_get_manufacturing_wage_inventory_account_id', lambda: inventory.id)
    return _account('5', 'مصروف مصنعية تالفة', type='Expense')


def _post(headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/melting-renewal', headers=headers, json=body)


def _vouchers_from(box):
    ids = {t.ref_id for t in SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type='voucher').all()}
    return Voucher.query.filter(Voucher.id.in_(ids)).all() if ids else []


def test_three_karats_are_one_voucher_and_the_wage_is_posted_once(auth_headers, capitalized_wages):
    source, target = _gold_safe('معروض'), _gold_safe('كسر')
    _ledger(source, 21, 10.0)
    _ledger(source, 18, 10.0)
    resp = _post(auth_headers, {
        'operation_type': 'melting', 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
        'lines': [{'karat': 21, 'gold_weight': 2.0}, {'karat': 18, 'gold_weight': 1.5},
                  {'karat': 21, 'gold_weight': 0.5}],
        'damage_wage_amount': 100.0, 'damage_wage_account_id': capitalized_wages.id,
    })
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]

    vouchers = _vouchers_from(source)
    assert len(vouchers) == 1
    lines = VoucherAccountLine.query.filter_by(voucher_id=vouchers[0].id).all()
    wage = [l for l in lines if l.account_id == capitalized_wages.id]
    assert [l.amount for l in wage] == [100.0]
    out_gold = sorted((l.karat, l.amount) for l in lines
                      if l.account_id == source.account_id and l.line_type == 'credit')
    assert out_gold == [(18.0, 1.5), (21.0, 0.5), (21.0, 2.0)]


def test_a_refused_line_posts_nothing(auth_headers, capitalized_wages):
    source, target = _gold_safe('معروض'), _gold_safe('كسر')
    _ledger(source, 21, 10.0)
    _ledger(source, 18, 1.0)
    resp = _post(auth_headers, {
        'operation_type': 'melting', 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
        'lines': [{'karat': 21, 'gold_weight': 2.0}, {'karat': 18, 'gold_weight': 1.5}],
        'damage_wage_amount': 100.0, 'damage_wage_account_id': capitalized_wages.id,
    })
    assert resp.status_code == 400 and resp.get_json()['error'] == 'insufficient_balance'
    assert resp.get_json()['karat'] == 18
    assert _vouchers_from(source) == []


def test_a_karats_lines_are_checked_together(auth_headers):
    """Two lines of 21k, each within the 3 g held, are not within it together."""
    source, target = _gold_safe('معروض'), _gold_safe('كسر')
    _ledger(source, 21, 3.0)
    resp = _post(auth_headers, {
        'operation_type': 'renewal', 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
        'lines': [{'karat': 21, 'gold_weight': 2.0}, {'karat': 21, 'gold_weight': 2.0}],
    })
    assert resp.status_code == 400 and resp.get_json()['available'] == 3.0
    assert _vouchers_from(source) == []


def test_the_one_line_body_is_as_before(auth_headers, capitalized_wages):
    source, target = _gold_safe('معروض'), _gold_safe('كسر')
    _ledger(source, 21, 10.0)
    resp = _post(auth_headers, {
        'operation_type': 'melting', 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
        'from_karat': 21, 'gold_weight': 2.0, 'stones_weight': 0.0,
        'damage_wage_amount': 40.0, 'damage_wage_account_id': capitalized_wages.id,
    })
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    (voucher,) = _vouchers_from(source)
    assert voucher.description.startswith('تكسير: 2.000 جم 21k')
    lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
    assert sorted((l.line_type, l.amount_type, l.amount) for l in lines) == [
        ('credit', 'cash', 40.0), ('credit', 'gold', 2.0), ('debit', 'cash', 40.0), ('debit', 'gold', 2.0)]
    rows = SafeBoxTransaction.query.filter_by(ref_type='voucher', ref_id=voucher.id).all()
    assert sorted((r.direction, r.weight_21k) for r in rows) == [('in', 2.0), ('out', 2.0)]


@pytest.mark.parametrize('lines', [[], 'x', [{'karat': 20, 'gold_weight': 1.0}], [{'karat': 21, 'gold_weight': 0}]],
                         ids=['empty', 'not a list', 'no such karat', 'no weight'])
def test_bad_lines_are_refused(auth_headers, lines):
    source, target = _gold_safe('معروض'), _gold_safe('كسر')
    resp = _post(auth_headers, {'operation_type': 'melting', 'from_safe_box_id': source.id,
                                'to_safe_box_id': target.id, 'lines': lines})
    assert resp.status_code == 400
