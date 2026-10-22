"""The safes screen's «تصحيح العيار»: the purity's difference is a weight lost or gained (SAFE-KARAT-001).

POST /safe-boxes/<id>/correct-karat moves X g from a karat to another within
one safe, gram for gram. It wrote nothing for the purity's difference: 1.5 g
of 21k relabelled 18k left the pool 0.214 main-karat grams lighter against no
account -- and from the gold-cost day (ADR-042) it was refused, a pool's gold
moving with nothing to carry its value.

The owner (22 Oct 2026): «فرق النقاوة إما فقد وزن أو وزن مكتسب»: a piece bought
as a lower karat that assays higher is a weight gained; the reverse a weight
lost. So the difference, in main-karat grams, goes to «فقد وزن بتصحيح العيار»
(a weight expense) or «مكسب وزني بتصحيح العيار» (a weight revenue) -- roles
mapped in «الربط المحاسبي»; unmapped, refused saying where. From the cost day
the difference carries its value at the pool's average.

Run:
    python -m pytest tests/test_safe_karat_correction_from_the_cost_day.py -v
"""
from datetime import date

import pytest

from accounting.chart_tree import role_account_id
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from app import app as flask_app
from models import AccountingMapping, JournalEntryLine, Settings, Voucher, db
from tests.test_gold_moves_with_its_value import _map, _valued, _weight_child
from tests.test_melting_and_renewal_go_one_way import _holds, _safe

LOSS, GAIN = 'karat_correction_loss', 'karat_correction_gain'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


@pytest.fixture
def roles():
    return {LOSS: _map(LOSS, _weight_child('operating_expenses_root', 'فقد وزن بتصحيح العيار وزني')),
            GAIN: _map(GAIN, _weight_child('revenue_root', 'مكسب وزني بتصحيح العيار وزني'))}


def _correct(headers, safe, from_karat, to_karat, weight):
    return flask_app.test_client().post(f'/api/safe-boxes/{safe.id}/correct-karat', headers=headers,
                                        json={'from_karat': from_karat, 'to_karat': to_karat, 'weight': weight,
                                              'notes': 'تحليل'})


def _lines(resp):
    entry = db.session.get(Voucher, resp.get_json()['voucher']['id']).journal_entry_id
    return entry, JournalEntryLine.query.filter_by(journal_entry_id=entry, is_deleted=False).all()


def _main_grams(line):
    return sum((float(getattr(line, f'debit_{k}k') or 0) - float(getattr(line, f'credit_{k}k') or 0)) * k / 21.0
               for k in (18, 21, 22, 24))


def test_a_karat_found_lower_is_a_weight_lost(auth_headers, roles):
    safe = _safe('scrap')
    _holds(safe, 21, 5.0)
    resp = _correct(auth_headers, safe, 21, 18, 1.5)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    _, lines = _lines(resp)
    loss = [l for l in lines if l.account_id == roles[LOSS].id]
    assert sum(_main_grams(l) for l in loss) == pytest.approx(1.5 * 3 / 21, abs=1e-3), '0.214 g lost'
    assert sum(_main_grams(l) for l in lines) == pytest.approx(0.0, abs=1e-6), 'the entry balances by purity'


def test_a_karat_found_higher_is_a_weight_gained(auth_headers, roles):
    safe = _safe('scrap')
    _holds(safe, 18, 5.0)
    resp = _correct(auth_headers, safe, 18, 21, 1.5)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    _, lines = _lines(resp)
    gain = [l for l in lines if l.account_id == roles[GAIN].id]
    assert sum(_main_grams(l) for l in gain) == pytest.approx(-1.5 * 3 / 21, abs=1e-3), '0.214 g gained'


def test_unmapped_it_is_refused_saying_where(auth_headers):
    AccountingMapping.query.filter(AccountingMapping.account_type.in_((LOSS, GAIN))).delete(synchronize_session=False)
    safe = _safe('scrap')
    _holds(safe, 21, 5.0)
    resp = _correct(auth_headers, safe, 21, 18, 1.5)
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']


def test_a_safes_karat_corrected_from_the_cost_day_posts(auth_headers, roles):
    """It was the xfail witness of SAFE-KARAT-001: from the cost day the
    correction posts, its weight lost carrying its value at the pool's average."""
    Settings.query.first().gold_cost_from = date(2026, 1, 1)
    db.session.flush()
    safe = _safe('scrap')
    _holds(safe, 21, 5.0)
    from services.gold_cost import pool_state
    _holds(_safe('scrap'), 21, 50.0 - min(pool_state('scrap').weight, 0.0))
    _valued('scrap', pool_state('scrap').weight * 400.0)
    resp = _correct(auth_headers, safe, 21, 18, 1.5)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    entry, _ = _lines(resp)
    stock = role_account_id('gold_inventory_scrap')
    written = sum(float(l.cash_debit or 0) - float(l.cash_credit or 0)
                  for l in JournalEntryLine.query.filter_by(journal_entry_id=entry, account_id=stock))
    assert written == pytest.approx(-round(1.5 * 3 / 21 * 400.0, 2), abs=0.02), 'the lost grams leave at 400'
