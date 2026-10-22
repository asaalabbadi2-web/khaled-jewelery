"""SAFE-KARAT-001: the safes screen's «تصحيح العيار» from the gold-cost day (xfail witness).

POST /safe-boxes/<id>/correct-karat moves X g from a karat to another within
one safe, gram for gram, on the safe's own account -- 1.5 g of 21k relabelled
18k leaves the pool 0.214 main-karat grams lighter, against nothing: the
purity's difference is written nowhere. From the settings' day (ADR-042
phase 3) every movement of a pool's gold carries its value, and this one has
no account to carry it: refused (gold_cost_counter_not_built). An invoice's
karat entered wrong is corrected by its invoice (ADR-056); this path is for a
safe's own mislabel. The terminal fix gives it a counter -- a decision for the
owner (the purity's difference: a loss or gain of weight). Until then this
test fails; it passes the day the path is built, and must then lose its mark.

Run:
    python -m pytest tests/test_safe_karat_correction_from_the_cost_day.py -v
"""
from datetime import date

import pytest

from app import app as flask_app
from models import Settings, db
from tests.test_melting_and_renewal_go_one_way import _holds, _safe


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


@pytest.mark.xfail(strict=True, reason='SAFE-KARAT-001: no account carries the purity difference from the cost day')
def test_a_safes_karat_corrected_from_the_cost_day_posts(auth_headers):
    Settings.query.first().gold_cost_from = date(2026, 1, 1)
    db.session.flush()
    safe = _safe('scrap')
    _holds(safe, 21, 5.0)
    resp = flask_app.test_client().post(f'/api/safe-boxes/{safe.id}/correct-karat', headers=auth_headers,
                                        json={'from_karat': 21, 'to_karat': 18, 'weight': 1.5, 'notes': 'تمرين'})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:300]
