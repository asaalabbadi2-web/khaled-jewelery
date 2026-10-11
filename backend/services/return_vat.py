"""The VAT a return reverses is its original's, as posted (ADR-043, rule 3).

A sale return took its VAT from what the screen sent -- else the return's
total_tax, else the original's total_tax: 15/115 of the whole total, which
disagrees with the posting on 91 invoices of January-April 2026 (24k is exempt),
and whole even for a partial return. A purchase return did the same with input
VAT. Now it is read from the original:

    the original's VAT still owed -- its posted entries on the role's accounts;
    for sales, none in a month moved to revenue (stage-4 item 22)
    x the returned share of its taxable lines -- by their value; an exempt
      karat is no part of a sale's VAT; a returned line matched to its
      original line, else valued at its karat's price per gram in the original
    capped by what earlier returns of the same original have not reversed

A return with no original reverses none, and one carrying VAT is refused.
"""
from __future__ import annotations

import json
from collections import defaultdict

from sqlalchemy import func

from accounting.balances import counted_line_filters
from accounting.mappings import get_account_id_for_mapping
from models import Invoice, InvoiceItem, InvoiceKaratLine, JournalEntry, JournalEntryLine, Settings, db
from services.sales_vat import posted_sales_vat, sales_vat_account_ids

OUTPUT, INPUT = 'output', 'input'
RETURN_TYPES = ('مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)')


class ReturnVatWithoutOriginal(ValueError):
    def __init__(self):
        super().__init__('مرتجع يحمل ضريبة بلا فاتورته الأصلية: الضريبة تُعكس من الأصل كما رُحّلت')


def _input_vat_account_ids() -> set[int]:
    return {a for a in (get_account_id_for_mapping('شراء', 'vat_receivable'),
                        get_account_id_for_mapping('شراء من عميل', 'vat_receivable')) if a}


def _posted(invoice_ids, kind) -> float:
    """VAT the invoices' posted entries carry for *kind* -- output credited, input debited."""
    if kind == OUTPUT:
        return sum(posted_sales_vat(invoice_ids).values())
    accounts = _input_vat_account_ids()
    if not accounts or not invoice_ids:
        return 0.0
    v = (db.session.query(func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(*counted_line_filters(), JournalEntry.reference_type == 'invoice',
                 JournalEntry.reference_id.in_(list(invoice_ids)), JournalEntryLine.account_id.in_(accounts))
         .scalar())
    return abs(float(v or 0))


def _recovered(invoice) -> bool:
    from services.vat_policy import policy_on
    return policy_on(invoice.date.date()).input_vat_recoverable


def _recorded(invoice) -> float:
    """The VAT an invoice records -- its wages' and gold's, else its total."""
    split = float(invoice.wage_tax_total or 0) + float(invoice.gold_tax_total or 0)
    return split if split > 0 else float(invoice.total_tax or 0)


def _exempt_karats() -> set[int]:
    row = Settings.query.first()
    try:
        raw = json.loads(row.vat_exempt_karats) if row and isinstance(row.vat_exempt_karats, str) else None
        return {int(float(k)) for k in (raw if raw is not None else [24])}
    except Exception:
        return {24}


def _value(item) -> float:
    """A line's value: its price -- else, on a supplier's purchase whose VAT is on
    the wages, its wage per gram x its weight -- else its weight."""
    price = float(item.price or item.net or 0) * float(item.quantity or 1)
    if price > 0:
        return price
    wage = float(item.wage or 0) * float(item.weight or 0)
    return wage if wage > 0 else float(item.weight or 0)


def _lines(invoice) -> list[tuple[int | None, float, float, float]]:
    """(item id, karat, weight, value) of each line -- its items, or its karat
    lines where it has none (a supplier's purchase: wages and gold value)."""
    items = InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id).all()
    if items:
        return [(i.id, float(i.karat or 0), float(i.weight or 0), _value(i)) for i in items]
    return [(None, float(k.karat or 0), float(k.weight_grams or 0),
             float(k.manufacturing_wage_cash or 0) + float(k.gold_value_cash or 0))
            for k in InvoiceKaratLine.query.filter_by(invoice_id=invoice.id).order_by(InvoiceKaratLine.id).all()]


def matches_from_request(ret, items_data) -> dict:
    """{return item id: the original item id its request line named} -- the
    lines are saved in the request's order."""
    saved = InvoiceItem.query.filter_by(invoice_id=ret.id).order_by(InvoiceItem.id).all()
    out = {}
    for item, data in zip(saved, items_data or []):
        try:
            if data.get('original_invoice_item_id'):
                out[item.id] = int(data['original_invoice_item_id'])
        except (TypeError, ValueError, AttributeError):
            pass
    return out


def _share(ret, original, kind, matched_ids=None) -> float:
    exempt = _exempt_karats() if kind == OUTPUT else set()
    taxable = lambda karat: int(round(karat)) not in exempt
    orig = _lines(original)
    base = sum(v for _, k, _, v in orig if taxable(k))
    if base <= 0:
        return 0.0
    per_gram = defaultdict(lambda: [0.0, 0.0])
    for _, k, w, v in orig:
        per_gram[k][0] += w
        per_gram[k][1] += v
    by_id = {i: (k, w, v) for i, k, w, v in orig}
    free = list(orig)              # original lines not matched yet, one each
    returned = 0.0
    matched_ids = matched_ids or {}
    for rid, k, w, v in _lines(ret):
        if not taxable(k):
            continue
        hit = by_id.get(matched_ids.get(rid))
        if hit is None:
            for n, (_, ok, ow, ov) in enumerate(free):
                if abs(ok - k) < 0.01 and abs(ow - w) < 0.001:
                    hit = (ok, ow, ov)
                    del free[n]
                    break
        if hit is not None and hit[1] > 0:
            returned += hit[2] * min(w / hit[1], 1.0)
        elif per_gram[k][0] > 0:
            returned += per_gram[k][1] / per_gram[k][0] * w
    return min(returned / base, 1.0)


def vat_to_reverse(ret: Invoice, original: Invoice | None, kind: str, *, sent: float = 0.0,
                   matched_ids: dict | None = None) -> float:
    """The VAT *ret* reverses of *original*'s (rule 3). *matched_ids*: {return item id: original item id}."""
    if original is None:
        if float(sent or 0) > 0.005:
            raise ReturnVatWithoutOriginal()
        return 0.0
    earlier = [i for (i,) in db.session.query(Invoice.id).filter(
        Invoice.original_invoice_id == original.id, Invoice.id != ret.id,
        Invoice.invoice_type.in_(RETURN_TYPES)).all()]
    if kind == INPUT and not _recovered(original):
        # Not recovered (rule 1): the VAT went into the cost, not onto 1400 -- read
        # it from the invoice, and earlier returns' from theirs.
        owed = _recorded(original)
        reversed_ = sum(_recorded(db.session.get(Invoice, i)) for i in earlier)
    else:
        owed = _posted([original.id], kind)
        reversed_ = _posted(earlier, kind)
    if owed <= 0.005:
        return 0.0
    left = owed - reversed_
    return round(max(0.0, min(owed * _share(ret, original, kind, matched_ids), left)), 2)
