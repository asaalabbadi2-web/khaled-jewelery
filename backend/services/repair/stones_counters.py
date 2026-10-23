"""The safes' stones counters zeroed, once, by a written row (ADR-050 ت6د).

The owner (23 Oct 2026): «نريد معالجة لعداد الفصوص في الخزائن حتى يتم
تصفيرها». A counter is the safe-box rows' stones, not the ledger (ADR-055).
On the 23 Oct copy 6.2 g sat on five counters whose stones were gone: 2.9 g
on the showroom's -- two renewals put them there and their pieces left as
gold at the standing weight -- and 3.3 g on four custodies whose scrap left
without them, before stones moved with their gold (ت6أ).

Per safe, its stones by karat (services/safe_stones) are brought to nothing
by a row out of what is above it and a row into what is below it, each
karat stamped; what an old row held as a total alone is zeroed in the total.
The rows that made the counter stay. A second run finds nothing. Caller
commits; the CLI rolls back a dry run.
"""
from __future__ import annotations

import json

from models import AuditLog, SafeBox, SafeBoxTransaction, db
from services.safe_stones import KARATS, stones_by_karat

REFERENCE = 'stones_counter_zeroed'
EPS = 1e-6
NOTE = 'تصفير عدّاد الفصوص (ADR-050 ت6د): فصوص 2026 التي لم تعد في الخزينة'


def _row(safe_id, direction, karats: dict, total: float, *, by, now):
    db.session.add(SafeBoxTransaction(
        safe_box_id=safe_id, ref_type=REFERENCE, ref_id=0, direction=direction, amount_cash=0.0,
        stones_weight=round(total, 6), notes=NOTE, created_by=by, created_at=now,
        **{f'stones_{k}k': round(v, 6) for k, v in karats.items()}))


def zero_counters(*, by: str, now) -> dict:
    """Every safe's stones counter to nothing; what each held, said."""
    out = {'safes': []}
    for safe_id, sums in sorted(stones_by_karat().items()):
        by_karat = {k: sums[k] for k in KARATS}
        loose = sums['total'] - sum(by_karat.values())          # an old row's total alone
        above = {k: v for k, v in by_karat.items() if v > EPS}
        below = {k: -v for k, v in by_karat.items() if v < -EPS}
        out_total = sum(above.values()) + max(loose, 0.0)
        in_total = sum(below.values()) + max(-loose, 0.0)
        if out_total <= EPS and in_total <= EPS:
            continue
        if out_total > EPS:
            _row(safe_id, 'out', above, out_total, by=by, now=now)
        if in_total > EPS:
            _row(safe_id, 'in', below, in_total, by=by, now=now)
        safe = db.session.get(SafeBox, safe_id)
        out['safes'].append({'safe_box_id': safe_id, 'safe': getattr(safe, 'name', None),
                             'held': {k: round(v, 3) for k, v in sums.items() if abs(v) > EPS}})
    if out['safes']:
        db.session.add(AuditLog(user_name=by, action=REFERENCE, entity_type='safe_box', entity_id=0,
                                details=json.dumps(out, ensure_ascii=False, default=str), success=True))
    db.session.flush()
    return out
