"""The safes' 2026 stones counters are zeroed, once, by a written row (ADR-050 ت6د).

The owner (23 Oct 2026): «نريد معالجة لعداد الفصوص في الخزائن حتى يتم
تصفيرها». On the 23 Oct copy 6.2 g sit on five counters whose stones are
gone: 2.9 g on the showroom's -- two renewals put them there, and their pieces
left as gold at the standing weight -- and 3.3 g on four custodies whose
scrap left without them (before ت6أ). A counter is not the ledger: it is
zeroed by a row per safe that says so, never by deleting the rows that made
it. A second run finds nothing to zero.

Run:
    python -m pytest tests/test_stones_counters_zeroed.py -v
"""
from datetime import datetime

import pytest

from models import AuditLog, SafeBoxTransaction, db
from services.repair.stones_counters import REFERENCE, zero_counters
from services.safe_stones import stones_of
from tests.test_gold_sufficiency_is_the_ledger import _gold_safe, app  # noqa: F401 (fixture)

NOW = datetime(2026, 10, 23, 15)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _row(box, direction, grams, karat=None):
    db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='invoice_scrap_receipt', ref_id=0,
                                      direction=direction, stones_weight=grams, created_by='t',
                                      **({f'stones_{karat}k': grams} if karat else {})))
    db.session.flush()


def test_every_counter_reads_zero_and_its_rows_stay(auth_headers):
    showroom, custody = _gold_safe('معروض'), _gold_safe('عهدة', 'custody')
    _row(showroom, 'in', 2.5, 18)
    _row(showroom, 'in', 0.4, 21)
    _row(custody, 'in', 1.5, 18)
    _row(custody, 'out', 0.2, 21)            # below nothing on 21k
    _row(custody, 'in', 0.3)                 # an old row: its total alone
    before = SafeBoxTransaction.query.count()

    result = zero_counters(by='test', now=NOW)

    for box in (showroom, custody):
        assert all(abs(v) < 1e-9 for v in _signed(box).values()), _signed(box)
    written = SafeBoxTransaction.query.filter_by(ref_type=REFERENCE).all()
    assert {r.safe_box_id for r in written} >= {showroom.id, custody.id}
    assert SafeBoxTransaction.query.count() > before, 'zeroed by rows, none deleted'
    assert {s['safe_box_id'] for s in result['safes']} >= {showroom.id, custody.id}
    assert AuditLog.query.filter_by(action=REFERENCE).count() == 1


def test_a_second_run_writes_nothing(auth_headers):
    showroom = _gold_safe('معروض')
    _row(showroom, 'in', 2.5, 18)
    zero_counters(by='test', now=NOW)
    count = SafeBoxTransaction.query.count()
    result = zero_counters(by='test', now=NOW)
    assert SafeBoxTransaction.query.count() == count
    assert result['safes'] == []


def _signed(box):
    from services.safe_stones import stones_by_karat
    return stones_by_karat(box.id).get(box.id, {'total': 0.0})
