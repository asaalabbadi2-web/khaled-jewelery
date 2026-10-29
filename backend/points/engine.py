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
PURCHASE_RETURN = 'مرتجع شراء'
# A return and what it returns: each takes back its original's points (the
# owner: a sale's, 10 Oct 2026; a customer purchase's, 22 Oct 2026).
RETURNS = {SALE_RETURN: 'بيع', PURCHASE_RETURN: 'شراء من عميل'}


def is_return(inv) -> bool:
    return str(getattr(inv, 'invoice_type', '') or '').strip() in RETURNS


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
    from models import _configured_main_karat_f
    mk = float(main_karat or _configured_main_karat_f())
    ow, rw = _weight_main(original, mk), _weight_main(ret, mk)
    if ow > 0:
        return min(1.0, max(0.0, rw / ow))
    ot, rt = float(getattr(original, 'total', 0.0) or 0.0), float(getattr(ret, 'total', 0.0) or 0.0)
    return min(1.0, max(0.0, rt / ot)) if ot > 0 else 1.0


def returns_against(original_filter, start_dt, end_dt, *, end_inclusive: bool = False) -> list:
    """Posted returns -- of sales and of customer purchases -- dated in
    [start_dt, end_dt) whose ORIGINAL matches *original_filter*: a function of
    the original's Invoice alias giving the condition that names the actor (the
    owner, 10 Oct 2026: a return takes its points back in the period it is
    made, from the one who sold; 22 Oct 2026: and from the one who bought)."""
    from sqlalchemy import and_
    from sqlalchemy.orm import aliased
    from models import Invoice
    original = aliased(Invoice)
    upper = Invoice.date <= end_dt if end_inclusive else Invoice.date < end_dt
    return (Invoice.query
            .join(original, original.id == Invoice.original_invoice_id)
            .filter(and_(Invoice.invoice_type.in_(tuple(RETURNS)),
                         Invoice.is_posted.is_(True),
                         Invoice.date >= start_dt, upper,
                         original.is_posted.is_(True),
                         original_filter(original)))
            .all())


class CorrectionDelta:
    """A correction (ADR-056) as the engine reads it: its invoice's points'
    difference, in the correction's own period, against the invoice's actor
    (the owner, 22 Oct 2026). Carries the original's type, employee and
    poster, what it was paid on and what is right."""
    is_correction = True
    items: list = []

    def __init__(self, correction, original):
        self.correction_id = correction.id
        self.original_invoice = original
        self.invoice_type = original.invoice_type
        self.employee_id = original.employee_id
        self.posted_by = original.posted_by
        self.date = correction.created_at
        before, after = correction.before or {}, correction.after or {}
        self.paid = before.get('profit') or {}
        self.right = after.get('profit') or {}
        self.total = float(correction.cash_delta or 0.0)
        self.weight = (float((after.get('invoice') or {}).get('total_weight') or 0.0)
                       - float((before.get('invoice') or {}).get('total_weight') or 0.0))
        self.profit_cash = float(self.right.get('profit_cash') or 0.0) - float(self.paid.get('profit_cash') or 0.0)
        self.profit_gold = float(self.right.get('profit_gold') or 0.0) - float(self.paid.get('profit_gold') or 0.0)


def is_correction(inv) -> bool:
    # strictly the delta's own flag: a stand-in invoice (a mock) answers any name
    return getattr(inv, 'is_correction', False) is True


def corrections_against(original_filter, start_dt, end_dt, *, end_inclusive: bool = False) -> list:
    """The corrections made in [start_dt, end_dt) of posted invoices whose
    original matches *original_filter* (as returns_against): each its points'
    difference in its own period, from the invoice's actor."""
    from models import Invoice, InvoiceCorrection
    upper = InvoiceCorrection.created_at <= end_dt if end_inclusive else InvoiceCorrection.created_at < end_dt
    rows = (db_query(InvoiceCorrection, Invoice)
            .join(Invoice, Invoice.id == InvoiceCorrection.invoice_id)
            .filter(InvoiceCorrection.created_at >= start_dt, upper, Invoice.is_posted.is_(True),
                    original_filter(Invoice))
            .order_by(InvoiceCorrection.id).all())
    return [CorrectionDelta(c, o) for c, o in rows]


def deficits_from():
    """The day an invoice's loss starts coming off its points (POINTS-DEFICIT-1,
    the owner 29 Oct 2026) -- the settings'; None: no loss counts."""
    from models import Settings
    settings = Settings.query.first()
    return getattr(settings, 'points_deficits_from', None) if settings is not None else None


def loss_counts(inv, since) -> bool:
    """Whether *inv*'s loss comes off its points: on or after the day."""
    when = getattr(inv, 'date', None)
    if since is None or when is None:
        return False
    return (when.date() if hasattr(when, 'date') else when) >= since


class _LossDay:
    """The day, read from the settings the first time a loss asks for it: an
    invoice list with no loss is scored without the database, as it was."""
    def __init__(self):
        self._read, self._day = False, None

    def counts(self, inv) -> bool:
        if not self._read:
            self._read, self._day = True, deficits_from()
        return loss_counts(inv, self._day)


def db_query(*entities):
    from models import db
    return db.session.query(*entities)


def _correction_points(c, *, points_source, cash_amount_per_point, points_per_gram, **_):
    """A correction's points: the right profit's points less the paid's, by the
    formula an invoice is scored by -- a loss below nothing only for an
    invoice its day counts (POINTS-DEFICIT-1), as the invoice is scored."""
    cpp, ppg = max(0.01, float(cash_amount_per_point)), max(0.0, float(points_per_gram))
    purchase = str(c.invoice_type or '').strip() == 'شراء من عميل'
    day = _LossDay()

    def scored(profit):
        pc, pg = float(profit.get('profit_cash') or 0.0), float(profit.get('profit_gold') or 0.0)
        counts = (pc < 0 or pg < 0) and day.counts(getattr(c, 'original_invoice', None))
        return _profit_points(pc, pg, purchase=purchase, counts=counts, points_source=points_source,
                              cpp=cpp, ppg=ppg)
    if points_source == 'sales_amount':
        return c.total / cpp
    if points_source == 'invoice_count':
        return 0.0
    if points_source == 'sold_weight':
        return c.weight * ppg
    return scored(c.right) - scored(c.paid)


def _profit_points(pc, pg, *, purchase, counts, points_source, cpp, ppg) -> float:
    """An invoice's points from its profits. A sale earns its cash profit (or,
    by grams, its gold profit); a customer's purchase too -- its gold at the
    market's buy price less what was paid (the owner, 29 Oct 2026) -- and one
    from before, which kept none, its grams. A loss below nothing comes off
    when *counts* (POINTS-DEFICIT-1); it was floored at nothing, and still is
    before the day."""
    if points_source == 'profit_cash':
        if purchase and pc == 0:
            # A purchase from before it had a cash profit (29 Oct 2026): its grams.
            return pg * ppg if pg > 0 or (counts and pg < 0) else 0.0
        return pc / cpp if pc > 0 or (counts and pc < 0) else 0.0
    return pg * ppg if pg > 0 or (counts and pg < 0) else 0.0      # gold_weight: the grams of profit


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

    A return in the list -- of a sale or of a customer purchase -- takes back
    the points of what it returns, in the share it returns (returned_share):
    the original's points, scored by this same formula, negative. Points earned
    before stay where they were paid: the return counts in its own period (the
    owner, 10 Oct 2026; purchases, 22 Oct 2026).
    """
    kwargs = dict(points_source=points_source, cash_amount_per_point=cash_amount_per_point,
                  points_per_gram=points_per_gram, point_rules=point_rules,
                  main_karat=main_karat, points_per_invoice=points_per_invoice)
    corrections = [i for i in invoices if is_correction(i)]
    returns = [i for i in invoices if is_return(i)]
    others = [i for i in invoices if not is_return(i) and not is_correction(i)]
    total = _points_of(others, **kwargs) if others else 0.0
    total += sum(_correction_points(c, **kwargs) for c in corrections)
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

    _day = _LossDay()

    # ── profit_cash mode ──────────────────────────────────────────────────────
    if points_source == 'profit_cash':
        # A purchase from a customer keeps its profit in grams (profit_gold),
        # not riyals (77720467, Jul 2026) -- the shared engine (6ff6b10b)
        # read only the grams, so a purchase's riyal profit earned nothing.
        total = 0.0
        for inv in invoices:
            pc = float(getattr(inv, 'profit_cash', 0.0) or 0.0)
            pg = float(getattr(inv, 'profit_gold', 0.0) or 0.0)
            total += _profit_points(pc, pg, purchase=_is_purchase(inv),
                                    counts=(pc < 0 or pg < 0) and _day.counts(inv),
                                    points_source='profit_cash', cpp=_cpp, ppg=_ppg)
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
        # A corrected invoice is read as it was posted (ADR-056): its lines'
        # weight less its corrections' -- those count in their own periods.
        corrected = _corrections_weight([getattr(inv, 'id', None) for inv in invoices])
        total_w = sum(
            max(0.0, float(item.weight or 0.0))
            for inv in invoices
            for item in (getattr(inv, 'items', None) or [])
        ) - sum(corrected.get(getattr(inv, 'id', None), 0.0) for inv in invoices)
        return total_w * _ppg

    # ── gold_weight mode (default) ────────────────────────────────────────────
    # Phase 1: accumulate per-(category, karat) buckets from InvoiceItem.profit_weight.
    # Phase 2: apply PointCalculator multiplier per bucket.
    # Backward-compat: invoices with no profit_weight on any item fall back to
    # invoice.profit_gold (permanent, matches pre-Phase-2C records).
    _mk = None   # read when a weight is converted -- the settings', never a fixed 21

    buckets: dict[tuple, float] = {}

    for inv in invoices:
        any_line = False
        for item in (getattr(inv, 'items', None) or []):
            karat = getattr(item, 'karat', None)
            if not karat:
                continue
            pw = float(getattr(item, 'profit_weight', 0.0) or 0.0)
            if pw == 0.0 or (pw < 0.0 and not _day.counts(inv)):     # a loss from the day (POINTS-DEFICIT-1)
                continue
            if _mk is None:
                from models import _configured_main_karat_f
                _mk = float(main_karat or _configured_main_karat_f())
            normalized = pw * float(karat) / _mk
            any_line = True
            bucket = (getattr(item, 'category_id', None), float(karat))
            buckets[bucket] = buckets.get(bucket, 0.0) + normalized

        if not any_line:
            pg = float(getattr(inv, 'profit_gold', 0.0) or 0.0)
            if pg > 0.0 or (pg < 0.0 and _day.counts(inv)):
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


def _corrections_weight(invoice_ids) -> dict:
    """Each corrected invoice's weight changed by its corrections (ADR-056)."""
    ids = [i for i in invoice_ids if i]
    if not ids:
        return {}
    from models import InvoiceCorrection
    out: dict = {}
    for c in InvoiceCorrection.query.filter(InvoiceCorrection.invoice_id.in_(ids)).all():
        before, after = (c.before or {}).get('invoice') or {}, (c.after or {}).get('invoice') or {}
        out[c.invoice_id] = out.get(c.invoice_id, 0.0) + (float(after.get('total_weight') or 0.0)
                                                          - float(before.get('total_weight') or 0.0))
    return out
