"""What a withdrawn sale and a sale return left behind (the owner, 10 Oct 2026).

Measured on the 10 Oct copy (pre-0fee5c78-20261010-011230):

- closing_orders: rejected sales 2821 (5,700 g), 3123 (3.457 g) and 3303
  (2.9 g) kept their weight-closing orders open -- 5,706 g waiting to take
  real purchases and book a cost of sale for sales that never were. None was
  executed. Each is cancelled, as rejecting now does
  (services/invoice_retraction_guard.withdraw_closing_order).

- return_categories: the five sale returns (946, 1032, 1035, 1089, 3300) were
  saved with uncategorised lines: the gold went back to the inventory ledger's
  no-category bucket and no category-weight movement was written, so the
  categories it came from (45, 28, 60, 55) stayed short -- 33.5 g of 21k and
  2.2 g of 18k. Each line takes its original line's category
  (services/return_lines.py, as a return now does when it is saved); the
  inventory ledger is reversed and posted again under it (append-only, a new
  cycle, as unposting and re-posting do); the category gets its weight back.

- return_costs: every sale return carried its own price as its cost (the
  return screen sends it so): 3300 1,200.00 against its sale's 925.23, 1035
  10,913.04 against 9,765.37. Each takes its sale's cost in the share it
  returns (services/return_lines.sale_return_cost, as a return now does when
  it is saved). A header figure only: no entry reads it.

No journal entry is written or changed: none of the three touches the ledger.
Every step is idempotent, writes one audit row, and in a dry run (the
default) writes nothing and says what it would do. A subject no longer as
measured -- an order with gold closed against it -- is refused, not guessed at.
"""
import json

from models import AuditLog, CategoryWeightMovement, Invoice, InvoiceItem, WeightClosingOrder, db

SALE_RETURN = 'مرتجع بيع'


class NotAsMeasured(ValueError):
    """The subject is no longer in the state the decision was made on."""


def _audit(by, action, entity_id, details):
    db.session.add(AuditLog(user_name=by, action=action, entity_type='invoice', entity_id=entity_id,
                            details=json.dumps(details, ensure_ascii=False, default=str), success=True))


def withdraw_open_closings(*, by: str, now, dry_run: bool = True) -> dict:
    """Cancel the open weight-closing orders of rejected invoices."""
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    from services.invoice_retraction_guard import closing_executions_of, withdraw_closing_order
    rows = (db.session.query(WeightClosingOrder, Invoice)
            .join(Invoice, Invoice.id == WeightClosingOrder.invoice_id)
            .filter(WeightClosingOrder.status.in_(['open', 'partially_closed']))
            .filter(db.func.coalesce(Invoice.status, '').in_(list(RETRACTED_INVOICE_STATUSES)))
            .order_by(Invoice.id).all())
    plan = []
    for order, invoice in rows:
        closed = closing_executions_of(invoice.id)
        if closed > 0:
            raise NotAsMeasured(f'invoice {invoice.id}: {closed} g already closed against order '
                                f'{order.order_number} -- not cancelled by this package')
        plan.append({'invoice_id': invoice.id, 'number': invoice.invoice_type_id,
                     'order_number': order.order_number,
                     'open_main_karat': round(float(order.remaining_weight_main_karat or 0.0), 3)})
        if not dry_run:
            withdraw_closing_order(invoice)
            _audit(by, 'withdraw_closing_order', invoice.id, {**plan[-1], 'at': now})
    if not dry_run:
        db.session.flush()
    return {'orders': plan, 'grams': round(sum(p['open_main_karat'] for p in plan), 3)}


def categorise_returns(*, by: str, now, dry_run: bool = True) -> dict:
    """Give each uncategorised sale-return line its original line's category,
    and the inventory ledger and the category weights what follows from it."""
    from category_weight_tracking import record_category_weight_movements_for_invoice_payload
    from services.inventory_posting_service import InventoryPostingService
    from services.return_lines import inherit_original_categories

    returns = (Invoice.query.filter(Invoice.invoice_type == SALE_RETURN, Invoice.is_posted.is_(True),
                                    Invoice.original_invoice_id.isnot(None))
               .order_by(Invoice.id).all())
    plan = []
    for ret in returns:
        lines = InvoiceItem.query.filter_by(invoice_id=ret.id).order_by(InvoiceItem.id).all()
        if not lines or all(line.category_id for line in lines):
            continue
        payload = [{'name': line.name, 'karat': line.karat, 'weight': line.weight,
                    'category_id': line.category_id} for line in lines]
        inherit_original_categories(payload, int(ret.original_invoice_id))
        found = [(line, row.get('category_id')) for line, row in zip(lines, payload)
                 if not line.category_id and row.get('category_id')]
        if not found:
            continue
        has_movements = CategoryWeightMovement.query.filter_by(invoice_id=ret.id).first() is not None
        step = {'return_id': ret.id, 'number': ret.invoice_type_id, 'original_id': ret.original_invoice_id,
                'lines': [{'line_id': line.id, 'name': line.name, 'karat': line.karat,
                           'weight': line.weight, 'category_id': cat} for line, cat in found],
                'category_weight_written': not has_movements}
        plan.append(step)
        if dry_run:
            continue
        InventoryPostingService.reverse(ret, reason=f'return {ret.id}: lines categorised as their original')
        for line, cat in found:
            line.category_id = int(cat)
        db.session.flush()
        InventoryPostingService.post(ret)
        if not has_movements:
            record_category_weight_movements_for_invoice_payload(
                invoice_id=ret.id,
                items_payload=[{'name': line.name, 'karat': line.karat, 'weight': line.weight,
                                'category_id': line.category_id} for line in lines])
        _audit(by, 'categorise_return_lines', ret.id, {**step, 'at': now})
    if not dry_run:
        db.session.flush()
    return {'returns': plan}


def correct_return_costs(*, by: str, now, dry_run: bool = True) -> dict:
    """Give each sale return its sale's cost, in the share it returns."""
    from services.return_lines import sale_return_cost
    returns = (Invoice.query.filter(Invoice.invoice_type == SALE_RETURN, Invoice.is_posted.is_(True),
                                    Invoice.original_invoice_id.isnot(None))
               .order_by(Invoice.id).all())
    plan = []
    for ret in returns:
        right = sale_return_cost(ret)
        if right is None or abs(float(ret.total_cost or 0.0) - right) < 0.005:
            continue
        plan.append({'return_id': ret.id, 'number': ret.invoice_type_id, 'original_id': ret.original_invoice_id,
                     'saved_cost': round(float(ret.total_cost or 0.0), 2), 'cost': right})
        if not dry_run:
            ret.total_cost = right
            _audit(by, 'correct_return_cost', ret.id, {**plan[-1], 'at': now})
    if not dry_run:
        db.session.flush()
    return {'returns': plan}


STEPS = (
    ('closing_orders', withdraw_open_closings),
    ('return_categories', categorise_returns),
    ('return_costs', correct_return_costs),
)


def run_package(*, by: str, now, dry_run: bool = True, only=None) -> dict:
    return {name: step(by=by, now=now, dry_run=dry_run) for name, step in STEPS
            if not only or name in only}
