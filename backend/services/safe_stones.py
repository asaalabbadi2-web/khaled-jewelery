"""The stones each gold safe holds, by karat: one reader.

A stone is not gold (ADR-055): its weight is on the safe-box rows, never in the
ledger. The stones-balance screen read them here, the transfer reads them to
keep stones with their gold (ADR-050 ت6أ).

A row with its karats filled (stones_18k..24k) says them; an older row only
its total -- spread over its gold karats by their weights, and kept in the
total alone when it has no gold either.
"""
from models import SafeBoxTransaction, db

KARATS = ('18', '21', '22', '24')


def _empty():
    return {'total': 0.0, **{k: 0.0 for k in KARATS}}


def stones_by_karat(safe_box_id=None, *, excluding_invoice_id=None):
    """{safe_box_id: {'total': g, '18': g, '21': g, '22': g, '24': g}} -- signed sums.
    excluding_invoice_id: before that invoice's own rows (a sale checks the
    stones it takes against the counter it found)."""
    q = db.session.query(SafeBoxTransaction).filter(SafeBoxTransaction.stones_weight > 0)
    if safe_box_id is not None:
        q = q.filter(SafeBoxTransaction.safe_box_id == safe_box_id)
    if excluding_invoice_id is not None:
        q = q.filter(db.or_(SafeBoxTransaction.invoice_id.is_(None),
                            SafeBoxTransaction.invoice_id != excluding_invoice_id))
    held = {}
    for row in q.all():
        sums = held.setdefault(row.safe_box_id, _empty())
        sign = 1.0 if row.direction == 'in' else -1.0
        total = float(row.stones_weight or 0.0)
        sums['total'] += sign * total
        by_karat = {k: float(getattr(row, f'stones_{k}k', 0.0) or 0.0) for k in KARATS}
        if sum(by_karat.values()) > 0.0001:
            for k in KARATS:
                sums[k] += sign * by_karat[k]
            continue
        gold = {k: float(getattr(row, f'weight_{k}k', 0.0) or 0.0) for k in KARATS}
        gold_total = sum(gold.values())
        if gold_total > 0.0001:
            for k in KARATS:
                sums[k] += sign * total * gold[k] / gold_total
    return held


def stones_of(safe_box_id, *, excluding_invoice_id=None):
    """One safe's stones: {'total': g, '18': g, ...}, each never below nothing."""
    sums = stones_by_karat(safe_box_id, excluding_invoice_id=excluding_invoice_id).get(safe_box_id, _empty())
    return {k: max(0.0, round(v, 6)) for k, v in sums.items()}
