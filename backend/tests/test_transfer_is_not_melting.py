"""A transfer moves gold as it is; scrap moves as scrap (the owner, 8 Nov 2026).

1. From the showroom to a scrap safe is a melting, from a scrap safe to the
   showroom a renewal: each has its voucher, which says the category, the
   damaged wage and what is not gold. The transfer voucher took them by
   weight alone -- 13 to the scrap (1,285 g) and 30 back (668 g) on the 5 Nov
   copy. Refused, saying the screen («يرفض»).
2. Scrap moved between scrap holders (a custody to the scrap safe, 413 lines,
   14,780 g) left its «كسر 21» behind: the custody kept the category, its
   «بلا تصنيف» went negative, the scrap safe took it «بلا تصنيف». The karat's
   scrap category goes with it -- as much as the source holds of it, the rest
   unclassified, as it was («نعم»).

Run:
    python -m pytest tests/test_transfer_is_not_melting.py -v
"""
import pytest

from app import app as flask_app
from models import Voucher
from tests.test_casting_and_assay import _held, _holds_scrap, _scrap_category
from tests.test_melting_and_renewal_go_one_way import _holds, _safe


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _transfer(headers, source, target, grams, karat=21):
    return flask_app.test_client().post('/api/safe-boxes/transfer-voucher', headers=headers, json={
        'from_safe_box_id': source.id, 'to_safe_box_id': target.id, 'weights': {f'{karat}k': grams}})


@pytest.mark.parametrize('ends', [('showroom', 'scrap'), ('scrap', 'showroom')])
def test_between_the_showroom_and_the_scrap_it_is_a_melting_or_a_renewal(auth_headers, ends):
    source, target = _safe(ends[0]), _safe(ends[1])
    _holds(source, 21, 10.0)
    before = Voucher.query.count()
    resp = _transfer(auth_headers, source, target, 5.0)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'melting_or_renewal_required'
    assert 'التجديد والتكسير' in body['message'], 'the screen it is done from'
    assert Voucher.query.count() == before


def test_scrap_moves_with_its_scrap_category(auth_headers):
    custody, scrap = _safe('custody'), _safe('scrap')
    _holds_scrap(custody, 21, 10.0)
    resp = _transfer(auth_headers, custody, scrap, 10.0)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    category = _scrap_category(21).id
    assert _held(custody) == {}, 'nothing left behind, nothing negative'
    assert _held(scrap) == {(21, category): 10.0}


def test_what_the_source_holds_unclassified_moves_unclassified(auth_headers):
    custody, scrap = _safe('custody'), _safe('scrap')
    _holds_scrap(custody, 21, 4.0)
    _holds(custody, 21, 6.0)  # unclassified
    assert _transfer(auth_headers, custody, scrap, 7.0).status_code == 201
    category = _scrap_category(21).id
    assert _held(custody) == {(21, None): 3.0}, '«كسر 21» given first, never below zero'
    assert _held(scrap) == {(21, category): 4.0, (21, None): 3.0}


def test_gold_that_is_not_scrap_still_moves_by_weight(auth_headers):
    """Item 3 (a worked transfer says its category) waits for the pieces."""
    showroom, custody = _safe('showroom'), _safe('custody')
    _holds(showroom, 21, 10.0)
    assert _transfer(auth_headers, showroom, custody, 4.0).status_code == 201
    assert _held(custody) == {(21, None): 4.0}
