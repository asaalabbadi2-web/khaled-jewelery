"""Stones move with their gold (ADR-050 ت6أ).

The owner (23 Oct 2026): «يجب أن يتم تحويله مع الذهب». A customer's scrap
enters a custody with its stones on the safe's counter (a stone is not gold:
its weight is the rows', not the ledger's). The transfer carried stones only
when typed, and none of the 201 that took custody gold to the main scrap on
the 21 Oct copy did: 7,554.7 g of gold left, 3.3 g of stones stayed on the
counters of custodies that no longer held the pieces.

The law: a transfer's stones are within the source's stones of their karat,
and a transfer that empties a karat takes that karat's stones with it.

Run:
    python -m pytest tests/test_stones_move_with_their_gold.py -v
"""
import pytest

from models import SafeBoxTransaction
from tests.test_gold_sufficiency_is_the_ledger import _gold_safe, _ledger_21k, _post, app  # noqa: F401 (fixture)
from models import db

PATH = '/api/safe-boxes/transfer-voucher'


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _stones_21k(box, grams):
    db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='invoice_scrap_receipt', ref_id=0,
                                      direction='in', stones_weight=grams, stones_21k=grams, created_by='t'))
    db.session.flush()


def _custody_with(gold, stones):
    custody, scrap = _gold_safe('عهدة', 'custody'), _gold_safe('كسر', 'scrap')
    _ledger_21k(custody, gold)
    _stones_21k(custody, stones)
    return custody, scrap


def _transfer(headers, source, target, gold, stones=None):
    body = {'from_safe_box_id': source.id, 'to_safe_box_id': target.id, 'weights': {'21k': gold}}
    if stones is not None:
        body['stones'] = {'21k': stones}
    return _post(PATH, headers, body)


def _stones_of(box, direction):
    return sum(r.stones_weight or 0.0 for r in SafeBoxTransaction.query.filter_by(
        safe_box_id=box.id, direction=direction, ref_type='voucher'))


def test_the_stones_go_with_the_gold(auth_headers):
    custody, scrap = _custody_with(10.0, 0.6)
    resp = _transfer(auth_headers, custody, scrap, 10.0, 0.6)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert _stones_of(custody, 'out') == pytest.approx(0.6)
    assert _stones_of(scrap, 'in') == pytest.approx(0.6)


def test_more_stones_than_the_source_holds_is_refused(auth_headers):
    custody, scrap = _custody_with(10.0, 0.6)
    resp = _transfer(auth_headers, custody, scrap, 10.0, 0.9)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'insufficient_stones_21k'
    assert body['available'] == pytest.approx(0.6)
    assert _stones_of(scrap, 'in') == 0.0


def test_emptying_a_karat_does_not_leave_its_stones_behind(auth_headers):
    custody, scrap = _custody_with(10.0, 0.6)
    resp = _transfer(auth_headers, custody, scrap, 10.0)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'stones_left_behind_21k'
    assert body['stones'] == pytest.approx(0.6)
    assert 'فصوص' in body['message']


def test_part_of_the_gold_takes_the_stones_the_employee_says(auth_headers):
    custody, scrap = _custody_with(10.0, 0.6)
    resp = _transfer(auth_headers, custody, scrap, 4.0, 0.2)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert _stones_of(scrap, 'in') == pytest.approx(0.2)
    resp = _transfer(auth_headers, custody, scrap, 3.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_a_safe_without_stones_moves_as_before(auth_headers):
    custody, scrap = _gold_safe('عهدة', 'custody'), _gold_safe('كسر', 'scrap')
    _ledger_21k(custody, 5.0)
    resp = _transfer(auth_headers, custody, scrap, 5.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
