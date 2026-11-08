"""Receiving before the invoice (ADR-087): from which day it works.

Settings.receiving_from, as Settings.gold_cost_from (ADR-042): NULL in 2026 --
a supplier's purchase posts whole, as it always has; the transition writes
2027's first day (services/transition_2027.opening_settings).
"""
from __future__ import annotations

from datetime import date, datetime

RECEIVED = 'received'
INVOICED = 'invoiced'


def receiving_from():
    from models import Settings
    return getattr(Settings.query.first(), 'receiving_from', None)


def receiving_on(day) -> bool:
    """Whether a supplier's purchase dated *day* is received first."""
    start = receiving_from()
    if start is None or day is None:
        return False
    if isinstance(day, datetime):
        day = day.date()
    return isinstance(day, date) and day >= start


# What receiving fixed and completing the invoice leaves as it is (ADR-087 §1).
RECEIPT_KEEPS = frozenset({
    'invoice_type_id', 'invoice_type', 'gold_type', 'customer_id', 'supplier_id', 'employee_id', 'branch_id',
    'office_id', 'date', 'original_invoice_id', 'return_reason', 'posted_by', 'total_weight',
    'scrap_holder_employee_id', 'barter_sale_invoice_id', 'request_key',
})


def _line_key(karat, weight, category_id):
    def num(v, places):
        try:
            return round(float(v or 0), places)
        except (TypeError, ValueError):
            return None
    return num(karat, 3), num(weight, 3), int(category_id) if category_id not in (None, '') else None


def completion_refusal(receipt, data: dict, *, posting_part: str):
    """Why an invoice cannot complete this document, or None (ADR-087 §1أ).

    Only a supplier's purchase received, by its cash part, for its supplier,
    with its very lines -- karat, weight, category -- in its order: weights
    other than the receipt's go by a documented settlement, not here.
    """
    from models import InvoiceItem
    if receipt.invoice_type != 'شراء' or receipt.receiving_stage != RECEIVED or posting_part != 'cash':
        return {'error': 'not_a_receipt', 'message': 'لا يُستكمل إلا مستند شراء مستلَم، بجزء النقد'}
    try:
        supplier_id = int(data.get('supplier_id') or 0)
    except (TypeError, ValueError):
        supplier_id = 0
    if supplier_id != int(receipt.supplier_id or 0):
        return {'error': 'receipt_supplier_differs', 'message': 'مورد الفاتورة غير مورد الاستلام'}
    received = [_line_key(l.karat, l.weight, l.category_id)
                for l in InvoiceItem.query.filter_by(invoice_id=receipt.id).order_by(InvoiceItem.id)]
    sent = [_line_key(i.get('karat'), i.get('weight'), i.get('category_id'))
            for i in (data.get('items') or []) if isinstance(i, dict)]
    if sent != received:
        return {'error': 'receipt_weights_differ',
                'message': 'أسطر الفاتورة غير أسطر الاستلام: الفرق يُسوّى بمستند تسوية موثّق، لا هنا'}
    return None
