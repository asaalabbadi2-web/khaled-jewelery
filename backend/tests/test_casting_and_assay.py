"""Casting and assay is «تصحيح العيار» with the weight it comes out at (8 Nov 2026).

On 15 Sep 2026 29.5 g of 18k scrap were cast and assayed 26.7 g of 21k: a
manual entry (JE-2026-05725) wrote it, its 1.414 g of 21k against «فرق الصب
والتحليل» -- a third account for the purity's difference, with no role. The
safes' «تصحيح العيار» moves grams from a karat to another gram for gram; the
casting changes both. Its difference is the purity's: what the fine gold came
out at less what went in, (26.7 x 21 - 29.5 x 18) / 21 = 1.4142857 g of 21k,
to «فرق نقاوة تصحيح العيار» (the owner, 8 Nov: «اليس لدينا حسابات فرق نقاوة»).
The weight out is the weight in unless said. In a scrap safe the scrap
category of the karat in leaves, the one of the karat out joins.

Run:
    python -m pytest tests/test_casting_and_assay.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Category, JournalEntry, JournalEntryLine, db
from tests.test_melting_and_renewal_go_one_way import _account, _safe
from tests.test_safe_karat_correction_from_the_cost_day import GAIN, _lines, _main_grams, roles  # noqa: F401

NOW = datetime(2026, 9, 1)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _scrap_category(karat):
    from services.categories import scrap_category
    found = scrap_category(karat)
    if found is None:
        found = Category(name=f'كسر {karat} {uuid.uuid4().hex[:4]}', karat=str(karat), is_scrap=True, is_active=True)
        db.session.add(found)
        db.session.flush()
    return found


def _holds_scrap(box, karat, grams):
    """Scrap in a scrap safe, classified its karat's scrap category -- every
    karat's scrap category there, as on production."""
    from services.stock_ledger import allocate
    for k in (18, 21, 22, 24):
        _scrap_category(k)
    other = _account('8', 'مقابل', type='Asset', tracks_weight=True)
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=NOW, description='t', is_posted=True)
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, **{f'debit_{karat}k': grams})
    db.session.add_all([line, JournalEntryLine(journal_entry_id=je.id, account_id=other.id,
                                               **{f'credit_{karat}k': grams})])
    db.session.flush()
    allocate(line, karat, _scrap_category(karat).id, grams, by='t', now=NOW)


def _cast(headers, safe, weight, weight_out=None):
    body = {'from_karat': 18, 'to_karat': 21, 'weight': weight, 'notes': 'صب وتحليل'}
    if weight_out is not None:
        body['weight_out'] = weight_out
    return flask_app.test_client().post(f'/api/safe-boxes/{safe.id}/correct-karat', headers=headers, json=body)


def _held(box):
    from services.stock_ledger import stock_balances
    return {(r['karat'], r['category_id']): round(r['grams'], 3) for r in stock_balances()
            if r['safe_box_id'] == box.id and abs(r['grams']) > 0.0005}


def test_cast_and_assayed_its_purity_difference_is_the_fine_golds(auth_headers, roles):
    safe = _safe('scrap')
    _holds_scrap(safe, 18, 29.5)
    resp = _cast(auth_headers, safe, 29.5, 26.7)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    _, lines = _lines(resp)
    on_safe = [l for l in lines if l.account_id == safe.account_id]
    assert sum(float(l.credit_18k or 0) for l in on_safe) == pytest.approx(29.5)
    assert sum(float(l.debit_21k or 0) for l in on_safe) == pytest.approx(26.7)
    gained = [l for l in lines if l.account_id == roles[GAIN].id]
    assert -sum(_main_grams(l) for l in gained) == pytest.approx((26.7 * 21 - 29.5 * 18) / 21, abs=1e-4), \
        'JE-2026-05725: 1.4142857 g of 21k'
    assert sum(_main_grams(l) for l in lines) == pytest.approx(0.0, abs=1e-6), 'the entry balances by purity'


def test_in_a_scrap_safe_the_scrap_category_follows_the_karat(auth_headers, roles):
    safe = _safe('scrap')
    _holds_scrap(safe, 18, 29.5)
    assert _cast(auth_headers, safe, 29.5, 26.7).status_code == 201
    assert _held(safe) == {(21, _scrap_category(21).id): 26.7}, 'nothing left «بلا تصنيف», nothing negative'


def test_the_weight_out_is_the_weight_in_unless_said(auth_headers, roles):
    safe = _safe('scrap')
    _holds_scrap(safe, 18, 10.0)
    assert _cast(auth_headers, safe, 10.0).status_code == 201
    assert _held(safe) == {(21, _scrap_category(21).id): 10.0}


@pytest.mark.parametrize('weight_out', [0, -1, 'x'])
def test_a_weight_out_that_is_no_weight_is_refused(auth_headers, roles, weight_out):
    safe = _safe('scrap')
    _holds_scrap(safe, 18, 10.0)
    resp = _cast(auth_headers, safe, 10.0, weight_out)
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'invalid_weight_out'


def test_the_scrap_category_never_goes_negative(auth_headers, roles):
    """The 5 Nov copy's main scrap safe: «كسر 18» 5.56, the rest of its 18k
    «بلا تصنيف». Casting 29.5 g took all of it from «كسر 18», left -23.94: the
    category gives what it holds, the unclassified the rest."""
    from tests.test_melting_and_renewal_go_one_way import _holds
    safe = _safe('scrap')
    _holds_scrap(safe, 18, 5.56)
    _holds(safe, 18, 46.17)  # unclassified
    assert _cast(auth_headers, safe, 29.5, 26.7).status_code == 201
    held = _held(safe)
    assert held.get((18, _scrap_category(18).id)) is None, '«كسر 18» emptied, not negative'
    assert held[(18, None)] == pytest.approx(5.56 + 46.17 - 29.5, abs=1e-3)
    assert held[(21, _scrap_category(21).id)] == pytest.approx(26.7)
