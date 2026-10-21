"""Melting and renewal say what category their gold leaves and enters (ت3).

The stock is the entry lines on stock safes, a category's share written by the
document that knows it (ADR-045, stock_line_allocation) -- the invoice did,
melting and renewal did not: their lines fell «بلا تصنيف». In 2026 that is all
of the stock (the owner's decision until the 31 Dec count); from the 2027
opening, a melting would have left the showroom's categories as they were and
pushed «بلا تصنيف» below zero, and a renewal put gold on the showroom under
no category that a sale then took out under one.

The owner (21 Oct 2026, docs/plans/melting-renewal-stones-roadmap.md, the
recommendations taken): a melting line names the category it leaves the
showroom from, and enters the scrap under its karat's scrap category; a
renewal line leaves under its karat's scrap category and names the category it
joins the showroom in. A line's category is of its karat; a melting does not
leave from a scrap category, nor a renewal join one. The allocation is written
in the posting's transaction: refused, nothing is posted.

Run:
    python -m pytest tests/test_melting_and_renewal_classify.py -v
"""
import uuid

import pytest

from models import Category, JournalEntryLine, StockLineAllocation, Voucher, db
from flask import g

from app import app as flask_app
from tests.test_melting_and_renewal_go_one_way import _holds, _safe


def _post(headers, body):
    """As sent -- no category filled in for it."""
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/melting-renewal', headers=headers, json=body)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _category(name, karat, *, scrap=False):
    if scrap:
        found = Category.query.filter_by(is_scrap=True, karat=str(karat)).first()
        if found is not None:
            return found
    c = Category(name=f'{name} {uuid.uuid4().hex[:5]}', karat=str(karat), is_scrap=scrap, is_active=True)
    db.session.add(c)
    db.session.flush()
    return c


def _allocations(voucher_id, account_id):
    v = db.session.get(Voucher, voucher_id)
    lines = JournalEntryLine.query.filter_by(journal_entry_id=v.journal_entry_id, account_id=account_id).all()
    return sorted((a.category_id, a.karat, a.grams) for a in StockLineAllocation.query.filter(
        StockLineAllocation.journal_entry_line_id.in_([l.id for l in lines] or [-1])).all())


def _op(kind, src, dst, *lines):
    return {'operation_type': kind, 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id, 'lines': list(lines)}


def test_a_melting_leaves_its_category_and_enters_its_karats_scrap(auth_headers):
    bangles, scrap21 = _category('بنجرة', 21), _category('كسر', 21, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 10.0)
    resp = _post(auth_headers, _op('melting', src, dst, {'karat': 21, 'gold_weight': 2.0, 'category_id': bangles.id}))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['voucher']['id']
    assert _allocations(vid, src.account_id) == [(bangles.id, 21, -2.0)]
    assert _allocations(vid, dst.account_id) == [(scrap21.id, 21, 2.0)]


def test_a_renewal_leaves_its_karats_scrap_and_joins_its_category(auth_headers):
    rings, scrap18 = _category('خاتم', 18), _category('كسر', 18, scrap=True)
    src, dst = _safe('custody'), _safe('showroom')
    _holds(src, 18, 10.0)
    resp = _post(auth_headers, _op('renewal', src, dst, {'karat': 18, 'gold_weight': 3.0, 'category_id': rings.id}))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['voucher']['id']
    assert _allocations(vid, src.account_id) == [(scrap18.id, 18, -3.0)]
    assert _allocations(vid, dst.account_id) == [(rings.id, 18, 3.0)]


def test_two_lines_of_a_karat_keep_their_two_categories(auth_headers):
    bangles, rings, scrap21 = _category('بنجرة', 21), _category('خاتم', 21), _category('كسر', 21, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 10.0)
    resp = _post(auth_headers, _op('melting', src, dst, {'karat': 21, 'gold_weight': 2.0, 'category_id': bangles.id},
                                   {'karat': 21, 'gold_weight': 1.5, 'category_id': rings.id}))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['voucher']['id']
    assert _allocations(vid, src.account_id) == sorted([(bangles.id, 21, -2.0), (rings.id, 21, -1.5)])
    assert sum(g for _, _, g in _allocations(vid, dst.account_id)) == pytest.approx(3.5)
    assert {c for c, _, _ in _allocations(vid, dst.account_id)} == {scrap21.id}


@pytest.mark.parametrize('case', ['missing', 'other_karat', 'scrap_side', 'unknown'])
def test_a_line_without_its_right_category_is_refused_and_posts_nothing(auth_headers, case):
    _category('كسر', 21, scrap=True)
    category = {'missing': None, 'other_karat': _category('بنجرة', 18).id,
                'scrap_side': _category('كسر', 21, scrap=True).id, 'unknown': 10**9}[case]
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 10.0)
    line = {'karat': 21, 'gold_weight': 2.0, **({'category_id': category} if category else {})}
    resp = _post(auth_headers, _op('melting', src, dst, line))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == {'missing': 'category_required', 'other_karat': 'category_karat_mismatch',
                                        'scrap_side': 'category_not_for_this_side',
                                        'unknown': 'category_not_found'}[case]
    assert resp.get_json()['message']
    assert Voucher.query.filter(Voucher.description.like(f'%{src.name}%')).count() == 0
