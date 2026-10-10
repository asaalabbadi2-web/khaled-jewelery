"""
points/engine.py — canonical points formula.

Single implementation shared by Race (PointsMetric) and Bonus (BonusCalculator).
Any change here propagates to both systems simultaneously — never duplicate this logic.

Public API:
    compute_invoices_points(invoices, *, points_source, cash_amount_per_point,
                            points_per_gram, point_rules=None, main_karat=None) -> float
"""
from __future__ import annotations


SALE_RETURN = 'مرتجع بيع'


def _weight_main(inv, mk: float) -> float:
    total = 0.0
    for item in (getattr(inv, 'items', None) or []):
        try:
            w, k = float(item.weight or 0.0), float(item.karat or 0.0)
        except (TypeError, ValueError):
            continue
        if w > 0 and k > 0:
            total += w * k / mk
    return total if total > 0 else max(0.0, float(getattr(inv, 'total_weight', 0.0) or 0.0))


def returned_share(ret, original, main_karat: float | None = None) -> float:
    """How much of *original* the return *ret* takes back: its weight's share,
    or its amount's when neither has weight; never more than all of it."""
    try:
        from models import _configured_main_karat_f
        mk = float(main_karat or _configured_main_karat_f())
    except Exception:
        mk = float(main_karat or 21.0)
    ow, rw = _weight_main(original, mk), _weight_main(ret, mk)
    if ow > 0:
        return min(1.0, max(0.0, rw / ow))
    ot, rt = float(getattr(original, 'total', 0.0) or 0.0), float(getattr(ret, 'total', 0.0) or 0.0)
    return min(1.0, max(0.0, rt / ot)) if ot > 0 else 1.0


def sale_returns_against(sale_filter, start_dt, end_dt, *, end_inclusive: bool = False) -> list:
    """Posted sale returns dated in [start_dt, end_dt) whose ORIGINAL sale
    matches *sale_filter* -- a function of the original's Invoice alias giving
    the condition that names the actor (the owner, 10 Oct 2026: a return takes
    its points back in the period it is made, from the one who sold)."""
    from sqlalchemy import and_
    from sqlalchemy.orm import aliased
    from models import Invoice
    original = aliased(Invoice)
    upper = Invoice.date <= end_dt if end_inclusive else Invoice.date < end_dt
    return (Invoice.query
            .join(original, original.id == Invoice.original_invoice_id)
            .filter(and_(Invoice.invoice_type == SALE_RETURN,
                         Invoice.is_posted.is_(True),
                         Invoice.date >= start_dt, upper,
                         original.is_posted.is_(True),
                         sale_filter(original)))
            .all())


def compute_invoices_points(
    invoices: list,
    *,
    points_source: str,
    cash_amount_per_point: float,
    points_per_gram: float,
    point_rules: list | None = None,
    main_karat: float | None = None,
    points_per_invoice: float = 1.0,
) -> float:
    """Return total points for a pre-filtered list of invoices (single actor).

    A sale return in the list takes back the points of the sale it returns, in
    the share it returns (returned_share) -- the original's points, scored by
    this same formula, negative. Points earned before stay where they were
    paid: the return counts in its own period (the owner, 10 Oct 2026).
    """
    kwargs = dict(points_source=points_source, cash_amount_per_point=cash_amount_per_point,
                  points_per_gram=points_per_gram, point_rules=point_rules,
                  main_karat=main_karat, points_per_invoice=points_per_invoice)
    returns = [i for i in invoices if str(getattr(i, 'invoice_type', '') or '').strip() == SALE_RETURN]
    others = [i for i in invoices if str(getattr(i, 'invoice_type', '') or '').strip() != SALE_RETURN]
    total = _points_of(others, **kwargs) if others else 0.0
    for ret in returns:
        original = getattr(ret, 'original_invoice', None)
        if original is None or not getattr(original, 'is_posted', False):
            continue
        total -= returned_share(ret, original, main_karat) * _points_of([original], **kwargs)
    return total


def _points_of(
    invoices: list,
    *,
    points_source: str,
    cash_amount_per_point: float,
    points_per_gram: float,
    point_rules: list | None = None,
    main_karat: float | None = None,
    points_per_invoice: float = 1.0,
) -> float:
    """The points of sales and purchases (no returns among them).

    Mirrors PointsMetric._group_and_score per-invoice logic exactly.

    Args:
        invoices:              Invoice ORM objects for one actor/employee.
        points_source:         'profit_cash' | 'gold_weight' | 'sales_amount' |
                               'invoice_count' | 'sold_weight'
        cash_amount_per_point: SAR per point (for profit_cash / sales_amount modes).
        points_per_gram:       pts per main-karat-equivalent gram.
        point_rules:           PointRule list for per-category multipliers (gold_weight mode).
        main_karat:            System main karat (read from Settings when None).
    """
    from points.calculator import PointCalculator

    _ppg     = max(0.0, float(points_per_gram))
    _cpp     = max(0.01, float(cash_amount_per_point))
    _rules   = list(point_rules or [])

    def _is_purchase(inv) -> bool:
        return str(getattr(inv, 'invoice_type', '') or '').strip() == 'شراء من عميل'

    # ── profit_cash mode ──────────────────────────────────────────────────────
    if points_source == 'profit_cash':
        total = 0.0
        for inv in invoices:
            if _is_purchase(inv):
                pg = max(0.0, float(getattr(inv, 'profit_gold', 0.0) or 0.0))
                total += pg * _ppg
            else:
                pc = max(0.0, float(getattr(inv, 'profit_cash', 0.0) or 0.0))
                total += pc / _cpp
        return total

    # ── sales_amount mode ─────────────────────────────────────────────────────
    if points_source == 'sales_amount':
        total = sum(
            max(0.0, float(getattr(inv, 'total', 0.0) or 0.0))
            for inv in invoices
        )
        return total / _cpp

    # ── invoice_count mode ────────────────────────────────────────────────────
    if points_source == 'invoice_count':
        return float(len(invoices)) * max(0.0, float(points_per_invoice))

    # ── sold_weight mode ──────────────────────────────────────────────────────
    if points_source == 'sold_weight':
        total_w = sum(
            max(0.0, float(item.weight or 0.0))
            for inv in invoices
            for item in (getattr(inv, 'items', None) or [])
        )
        return total_w * _ppg

    # ── gold_weight mode (default) ────────────────────────────────────────────
    # Phase 1: accumulate per-(category, karat) buckets from InvoiceItem.profit_weight.
    # Phase 2: apply PointCalculator multiplier per bucket.
    # Backward-compat: invoices with no profit_weight on any item fall back to
    # invoice.profit_gold (permanent, matches pre-Phase-2C records).
    try:
        from models import _configured_main_karat_f
        _mk = float(main_karat or _configured_main_karat_f())
    except Exception:
        _mk = float(main_karat or 21.0)

    buckets: dict[tuple, float] = {}

    for inv in invoices:
        inv_contributed = 0.0
        for item in (getattr(inv, 'items', None) or []):
            karat = getattr(item, 'karat', None)
            if not karat:
                continue
            pw = max(0.0, float(getattr(item, 'profit_weight', 0.0) or 0.0))
            if pw == 0.0:
                continue
            normalized = pw * float(karat) / _mk
            inv_contributed += normalized
            bucket = (getattr(item, 'category_id', None), float(karat))
            buckets[bucket] = buckets.get(bucket, 0.0) + normalized

        if inv_contributed == 0.0:
            pg = max(0.0, float(getattr(inv, 'profit_gold', 0.0) or 0.0))
            if pg > 0.0:
                fb = (None, None)
                buckets[fb] = buckets.get(fb, 0.0) + pg

    total = 0.0
    for (cat_id, karat), profit in buckets.items():
        multiplier = PointCalculator.calculate(
            category_id=cat_id,
            karat=karat,
            rules=_rules,
            default=_ppg,
        )
        total += profit * multiplier

    return total
