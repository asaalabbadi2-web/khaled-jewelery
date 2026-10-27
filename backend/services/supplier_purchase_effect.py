"""What a supplier purchase adds to what we owe the supplier -- one place.

ADR-060's follow-up (the owner, 25 Oct 2026, option أ): the purchase screen
worked out the effect on the supplier itself; the save worked it out again,
inline, in add_invoice. This is the one reading of the request both use: the
save takes its supplier lines' amounts from it, and the purchase preview
(before saving) says them -- so what is previewed is what is posted.

What the invoice adds to the supplier (ADR-061: the wage is cash, always):
  cash -- the gold's VAT, the wage and its VAT, priced stones and their VAT;
  gold -- grams by karat: the karat lines' weights, else the supplier's gold
          lines (or weights) the request names, else the items' gold.

What is paid with it (purchase_paid_now): the cash the request pays (its
payments, else amount_paid -- the save makes the one the other's sum) and the
gold it settles, by karat (gold_settlements, else settled_gold_weight at
settled_gold_karat).

It reads; it posts nothing. The one table it reads is an item's own karat and
weight, when a line names an item and not them -- as the save did.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from core.number_helpers import coerce_float


def _karat_key(value):
    """A karat's key ('21' for 21, 21.0 or '21') -- None when it is no number
    (as the save's)."""
    try:
        return str(int(round(float(value))))
    except (TypeError, ValueError):
        return None


def _weights(lines) -> dict:
    """{'21': g, ...} from a list of {karat, weight} or a {karat: weight} map."""
    out: dict = {}
    if isinstance(lines, list):
        for line in lines:
            key = _karat_key(line.get('karat'))
            weight = coerce_float(line.get('weight', 0), 0.0)
            if key and weight > 0:
                out[key] = out.get(key, 0.0) + weight
    elif isinstance(lines, dict):
        for karat, weight in lines.items():
            weight = coerce_float(weight, 0.0)
            key = _karat_key(karat)
            if key and weight > 0:
                out[key] = out.get(key, 0.0) + weight
    return out


def purchase_wage(data: dict) -> float:
    """A supplier purchase's wage, as its entry posts it -- the one reading
    (ADR-060): the payment check, the invoice's stored wage_subtotal and the
    supplier's entry all take it. They read wage_subtotal alone, the entry
    manufacturing_wage_cash first; a wage named only so was posted and never
    known to be owed."""
    return coerce_float(
        data.get('manufacturing_wage_cash')
        or data.get('wage_cash')
        or data.get('total_wage')
        or data.get('wage_subtotal')
        or 0,
        0.0,
    )


@dataclass(frozen=True)
class SupplierPurchaseOwed:
    """What the invoice adds to the supplier. Amounts are as the request says
    them; the save rounds them where it posts them, as it did."""

    gold_vat: float
    wage: float
    wage_vat: float
    stones: float
    stones_vat: float
    # The supplier's gold as the request names it (or the items'): what the
    # invoice records as paid in gold, and whether gold is owed at all.
    supplier_gold_by_karat: dict = field(default_factory=dict)
    # The gold the supplier's memo account is credited, by karat: the karat
    # lines' weights when the request has them, else supplier_gold_by_karat.
    posted_gold_by_karat: dict = field(default_factory=dict)

    @property
    def wage_payable(self) -> float:
        """The wage and its VAT: one cash credit."""
        return round(self.wage + self.wage_vat, 2)

    @property
    def stones_payable(self) -> float:
        return round(self.stones + self.stones_vat, 2) if self.stones > 0 else 0.0

    @property
    def cash(self) -> float:
        """Every cash credit the save posts on the supplier's account."""
        return round(round(self.gold_vat, 2) + self.wage_payable + self.stones_payable, 2)

    @property
    def gold_by_karat(self) -> dict:
        """The grams the supplier is credited -- none when it is owed no gold."""
        return dict(self.posted_gold_by_karat) if self.supplier_gold_by_karat else {}


def supplier_purchase_owed(data: dict, *, items_gold_by_karat: dict,
                           priced_stones_value: float = 0.0,
                           priced_stones_tax: float = 0.0) -> SupplierPurchaseOwed:
    """What a supplier purchase ('شراء') request adds to the supplier.

    [items_gold_by_karat] is the items' gold by karat key, as the save adds it
    up from the items (net of stones); [priced_stones_value] and
    [priced_stones_tax] as the save normalizes them (ت4).
    """
    supplier_gold = _weights(data.get('supplier_gold_lines') or data.get('supplier_gold_weights'))
    if not supplier_gold:
        supplier_gold = {k: v for k, v in (items_gold_by_karat or {}).items() if v > 0}

    karat_lines = data.get('karat_lines', [])
    from_lines: dict = {}
    if karat_lines and isinstance(karat_lines, list):
        for line in karat_lines:
            key = _karat_key(line.get('karat'))
            weight = coerce_float(line.get('weight_grams', 0), 0.0)
            if key and weight > 0:
                from_lines[key] = from_lines.get(key, 0.0) + weight

    return SupplierPurchaseOwed(
        gold_vat=coerce_float(data.get('gold_tax_total', 0), 0.0),
        wage=purchase_wage(data),
        wage_vat=coerce_float(data.get('wage_tax_total', 0), 0.0),
        stones=float(priced_stones_value or 0.0),
        stones_vat=float(priced_stones_tax or 0.0),
        supplier_gold_by_karat=supplier_gold,
        posted_gold_by_karat=dict(from_lines or supplier_gold),
    )


def items_gold_by_karat(data: dict) -> dict:
    """The gold the save adds up from a request, by karat key ('18'...'24'):
    the items' weights (an item's own when a line names it and not its
    weight), unless valid karat lines are sent -- then the karat lines alone
    (some clients send both). Every invoice type's, as add_invoice did inline.
    """
    from models import Item

    gold = {'18': 0.0, '21': 0.0, '22': 0.0, '24': 0.0}

    def register(karat, weight):
        karat = coerce_float(karat, 0.0)
        weight = coerce_float(weight, 0.0)
        if karat <= 0 or weight <= 0:
            return
        key = str(int(round(karat)))
        gold[key] = gold.get(key, 0.0) + weight

    karat_lines = data.get('karat_lines', [])
    valid_lines = False
    if karat_lines and isinstance(karat_lines, list):
        for line in karat_lines:
            if not isinstance(line, dict):
                continue
            if (coerce_float(line.get('karat'), 0.0) > 0 and coerce_float(
                    line.get('weight_grams', line.get('weight', line.get('total_weight'))), 0.0) > 0):
                valid_lines = True
                break

    if not valid_lines:
        for item_data in data.get('items', []):
            item_id = item_data.get('item_id')
            item = Item.query.get(item_id) if item_id else None
            karat = item_data.get('karat') if item_data.get('karat') not in (None, '') else (
                item.karat if item else None)
            weight = item_data.get('weight') if item_data.get('weight') is not None else (
                item.weight if item else None)
            if weight is None:
                weight = item_data.get('total_weight')
            register(karat, weight)

    if karat_lines and isinstance(karat_lines, list):
        for line in karat_lines:
            register(line.get('karat'), line.get('weight_grams', line.get('weight', line.get('total_weight'))))
    return gold


@dataclass(frozen=True)
class PaidNow:
    cash: float
    gold_by_karat: dict = field(default_factory=dict)


def purchase_paid_now(data: dict) -> PaidNow:
    """What a purchase request pays with it: cash, and gold by karat key."""
    payments = [p for p in (data.get('payments') or []) if isinstance(p, dict)]
    cash = (sum(coerce_float(p.get('amount'), 0.0) for p in payments) if payments
            else coerce_float(data.get('amount_paid'), 0.0))

    gold: dict = {}
    lines = data.get('gold_settlements')
    if isinstance(lines, list) and lines:
        for line in lines:
            if not isinstance(line, dict):
                continue
            key = _karat_key(line.get('karat'))
            weight = coerce_float(line.get('weight', line.get('weight_grams', 0.0)), 0.0)
            if key and weight > 0:
                gold[key] = gold.get(key, 0.0) + weight
    else:
        weight = coerce_float(data.get('settled_gold_weight'), 0.0)
        key = _karat_key(data.get('settled_gold_karat'))
        if key and weight > 0:
            gold[key] = weight
    return PaidNow(cash=round(cash, 2), gold_by_karat=gold)
