"""How a supplier payment spreads over the invoices the employee chose (VOUCHER-ATTR-1).

The owner (9 Oct 2026): the employee picks the invoices a payment is for; its
cash and its gold go to them in the order of their dates, oldest first, each
taking no more than it still owes; what is left stays on the supplier's
account -- a payment on account is legitimate -- and is said.

Not the auto-FIFO ADR-028 forbids: nothing goes to an invoice the employee did
not choose. The order only spreads a payment over the chosen ones.

The one place this is decided: the voucher screen shows its answer, and the
voucher records it (create_voucher writes the plan into its declared splits,
which approval attributes through attribute_cash_to_invoice and
attribute_gold_across_invoices -- each with its own guards).
"""
from __future__ import annotations

import math

from models import Invoice
from pricing.karat_service import convert_from_main_karat, convert_to_main_karat

CASH_EPSILON = 0.01
GOLD_EPSILON = 0.005


def _floor(value: float, digits: int) -> float:
    """Down, so a split never claims a hair more than the invoice owes."""
    factor = 10 ** digits
    return math.floor(value * factor + 1e-9) / factor


def chosen_invoices(supplier_id: int, invoice_ids) -> list:
    """The chosen invoices, oldest first. Raises ValueError('invoice_not_payable:<id>')
    for one that is not a standing invoice of this supplier."""
    from services.gold_allocation_service import invoice_obligation_is_live

    invoices = []
    for raw in dict.fromkeys(invoice_ids or []):
        try:
            invoice_id = int(raw)
        except (TypeError, ValueError):
            raise ValueError(f'invoice_not_payable:{raw}')
        invoice = Invoice.query.get(invoice_id)
        if (invoice is None or invoice.supplier_id != supplier_id
                or not invoice_obligation_is_live(invoice)):
            raise ValueError(f'invoice_not_payable:{invoice_id}')
        invoices.append(invoice)
    return sorted(invoices, key=lambda inv: (inv.date is None, inv.date, inv.id))


def plan_supplier_payment(*, supplier_id: int, invoice_ids, cash: float, gold) -> dict:
    """*gold*: [{'karat', 'weight'}] -- the payment's own karats. Returns the
    cash splits [{'invoice_id', 'amount'}], the gold splits [{'invoice_id',
    'karat', 'weight'}] in the real karat, what stays on account, and the
    chosen invoices with what each owes."""
    from services.gold_allocation_service import invoice_open_gold_obligation
    from services.invoice_payment_state_service import invoice_open_cash

    invoices = chosen_invoices(supplier_id, invoice_ids)
    open_cash = {inv.id: invoice_open_cash(inv) for inv in invoices}
    open_gold = {inv.id: invoice_open_gold_obligation(inv.id) for inv in invoices}

    cash_left = round(float(cash or 0.0), 2)
    cash_splits = []
    for inv in invoices:
        take = round(min(cash_left, open_cash[inv.id]), 2)
        if take > CASH_EPSILON:
            cash_splits.append({'invoice_id': inv.id, 'amount': take})
            cash_left = round(cash_left - take, 2)

    gold_room = dict(open_gold)
    gold_splits = []
    gold_left_main = 0.0
    for entry in gold or []:
        karat = float(entry.get('karat') or 0.0)
        weight = float(entry.get('weight') or 0.0)
        if karat <= 0 or weight <= 0:
            continue
        left_main = convert_to_main_karat(weight, karat)
        for inv in invoices:
            room = gold_room[inv.id]
            if left_main <= GOLD_EPSILON or room <= GOLD_EPSILON:
                continue
            split_weight = _floor(convert_from_main_karat(min(left_main, room), karat), 3)
            if split_weight <= 0:
                continue
            used_main = convert_to_main_karat(split_weight, karat)
            gold_splits.append({'invoice_id': inv.id, 'karat': karat, 'weight': split_weight})
            gold_room[inv.id] = room - used_main
            left_main -= used_main
        gold_left_main += max(0.0, left_main)

    return {
        'cash': cash_splits,
        'gold': gold_splits,
        'cash_on_account': round(max(0.0, cash_left), 2),
        'gold_on_account_main_karat': round(gold_left_main, 2),
        'invoices': [{
            'invoice_id': inv.id,
            'invoice_number': inv.invoice_number,
            'date': inv.date.isoformat() if inv.date else None,
            'open_cash': open_cash[inv.id],
            'open_gold_main_karat': open_gold[inv.id],
        } for inv in invoices],
    }
