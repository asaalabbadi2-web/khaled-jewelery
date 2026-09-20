"""Weight Closing Engine — settings loading and order execution."""
from __future__ import annotations

import json

from models import (
    db,
    Account,
    Invoice,
    InvoiceKaratLine,
    Settings,
    WeightClosingExecution,
    WeightClosingOrder,
)
from core.number_helpers import coerce_float as _coerce_float
from pricing.karat_service import convert_from_main_karat, convert_to_main_karat, get_main_karat
from pricing.gold_price_service import get_current_gold_price
from accounting.mappings import get_account_id_by_number
from dual_system_helpers import create_dual_journal_entry


DEFAULT_WEIGHT_CLOSING_SETTINGS = {
    'main_karat': 21,
    'price_source': 'live',
    'enabled': True,
    'allow_override': True,
    'shift_close_cash_deficit_threshold': 50.0,
    'shift_close_gold_pure_deficit_threshold_grams': 0.10,
    'order_number_prefix': 'WCO',
    'reservation_code_prefix': 'RES',
    'inventory_new_account_id': 1300,
    'inventory_scrap_account_id': 1310,
    'inventory_account_id': 1310,
    'cash_safe_box_id': None,
    'cash_account_id': 1100,
}


def _load_weight_closing_settings() -> dict:
    settings_row = Settings.query.first()
    if settings_row and settings_row.weight_closing_settings:
        try:
            payload = json.loads(settings_row.weight_closing_settings)
            if isinstance(payload, dict):
                merged = dict(DEFAULT_WEIGHT_CLOSING_SETTINGS)
                merged.update({k: v for k, v in payload.items() if v is not None})
                return merged
        except json.JSONDecodeError:
            pass
    return dict(DEFAULT_WEIGHT_CLOSING_SETTINGS)


def _auto_consume_weight_closing(
    source_invoice_id: int = None,
    *,
    weight_override=None,
    price_per_gram=None,
    cash_amount=None,
    execution_type: str = 'purchase_scrap',
    journal_entry_id=None,
    notes=None,
):
    # Lazy imports for helpers still in routes (avoid circular import).
    from routes import _invoice_weight_in_main_karat, _get_inventory_account_by_karat

    invoice = Invoice.query.get(source_invoice_id) if source_invoice_id else None

    requested_weight = _coerce_float(weight_override, None)
    execution_price = _coerce_float(price_per_gram, None)

    if requested_weight is None:
        if cash_amount is not None:
            if execution_price is None or execution_price <= 0:
                price_snapshot = get_current_gold_price()
                execution_price = price_snapshot.get('price_per_gram_24k', 0.0)
            grams_24k = (cash_amount or 0.0) / execution_price if execution_price else 0.0
            requested_weight = convert_to_main_karat(grams_24k, 24)
        elif invoice:
            requested_weight = _invoice_weight_in_main_karat(invoice)
        else:
            requested_weight = 0.0

    requested_weight = max(requested_weight or 0.0, 0.0)

    summary = {
        'weight_requested': requested_weight,
        'weight_consumed': 0.0,
        'executions_created': 0,
        'orders_updated': [],
        'orders_closed': [],
        'difference_value_total': 0.0,
        'difference_weight_total': 0.0,
        'cash_requested': round(cash_amount or 0.0, 2),
        'cash_consumed': 0.0,
    }

    if requested_weight <= 0:
        return summary

    orders = (
        WeightClosingOrder.query.filter(WeightClosingOrder.status.in_(['open', 'partially_closed']))
        .order_by(WeightClosingOrder.created_at.asc())
        .all()
    )

    remaining = requested_weight
    cash_spent = 0.0

    for order in orders:
        if remaining <= 0:
            break

        available = max((order.total_weight_main_karat or 0.0) - (order.executed_weight_main_karat or 0.0), 0.0)
        if available <= 0:
            order.status = 'closed'
            summary['orders_closed'].append(order.id)
            continue

        chunk = min(available, remaining)
        exec_price = execution_price if execution_price is not None else order.close_price_per_gram
        exec_price = _coerce_float(exec_price, 0.0)

        if journal_entry_id and invoice and execution_type != 'office_reservation':
            karat_line = InvoiceKaratLine.query.filter_by(invoice_id=invoice.id).first()
            execution_karat = karat_line.karat if karat_line else get_main_karat()

            _order_gold_kind = order.invoice.gold_type if order.invoice else 'new'
            inventory_account_id = _get_inventory_account_by_karat(execution_karat, kind=_order_gold_kind)

            bridge_account_id = (
                Account.query.filter_by(account_number='1710').first()
                or Account.query.filter_by(account_number='1290').first()
            )
            if not bridge_account_id:
                bridge_account_id = Account.query.filter_by(name='جسر مشتريات الكسر والتسكير').first()
            bridge_id = bridge_account_id.id if bridge_account_id else None

            if bridge_id:
                weight_in_karat = convert_from_main_karat(chunk, execution_karat)

                karat_debit = f'debit_{execution_karat}k'
                karat_credit = f'credit_{execution_karat}k'

                inventory_memo_acc_id = None
                try:
                    inv_obj = Account.query.get(inventory_account_id)
                    if inv_obj and inv_obj.memo_account_id:
                        inventory_memo_acc_id = inv_obj.memo_account_id
                except Exception:
                    inventory_memo_acc_id = None
                if not inventory_memo_acc_id:
                    inventory_memo_acc_id = get_account_id_by_number('7521')

                if inventory_memo_acc_id:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry_id,
                        account_id=inventory_memo_acc_id,
                        description=f'تنفيذ تسكير عيار {execution_karat}',
                        **{karat_debit: weight_in_karat}
                    )
                else:
                    print(f"⚠️ Skipping weight debit in weight closing: no memo account for inventory {inventory_account_id}")

                create_dual_journal_entry(
                    journal_entry_id=journal_entry_id,
                    account_id=bridge_id,
                    description=f'إخراج من جسر التسكير عيار {execution_karat}',
                    **{karat_credit: weight_in_karat}
                )

        chunk_24k = convert_from_main_karat(chunk, 24)
        chunk_cash_value = round(chunk_24k * exec_price, 2) if exec_price else 0.0
        cash_spent += chunk_cash_value

        if journal_entry_id and chunk_cash_value > 0 and execution_type not in ('expense', 'office_reservation'):
            _cogs_account = Account.query.filter_by(account_number='521').first()
            if _cogs_account:
                _karat_ln = (
                    InvoiceKaratLine.query.filter_by(invoice_id=invoice.id).first()
                    if invoice else None
                )
                _exec_karat_cogs = int(_karat_ln.karat) if _karat_ln else get_main_karat()
                _order_gold_kind_cogs = order.invoice.gold_type if order.invoice else 'new'
                _inv_fin_id = _get_inventory_account_by_karat(_exec_karat_cogs, kind=_order_gold_kind_cogs)
                if _inv_fin_id:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry_id,
                        account_id=_cogs_account.id,
                        cash_debit=chunk_cash_value,
                        description=(
                            f'تكلفة مبيعات ذهب – {round(chunk, 4)} غ عيار {_exec_karat_cogs}'
                        ),
                    )
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry_id,
                        account_id=_inv_fin_id,
                        cash_credit=chunk_cash_value,
                        description=(
                            f'إخراج من مخزون مالي لتكلفة المبيعات – عيار {_exec_karat_cogs}'
                        ),
                    )

        difference_value = 0.0
        difference_weight = 0.0
        reference_price = order.close_price_per_gram or 0.0

        if exec_price and reference_price:
            difference_value = round((exec_price - reference_price) * chunk_24k, 2)
            if reference_price > 0:
                baseline_grams_24k = chunk_cash_value / reference_price if reference_price else 0.0
                baseline_weight_main = convert_to_main_karat(baseline_grams_24k, 24)
                difference_weight = round(baseline_weight_main - chunk, 6)

        execution = WeightClosingExecution(
            order_id=order.id,
            source_invoice_id=invoice.id if invoice else None,
            execution_type=execution_type,
            weight_main_karat=chunk,
            price_per_gram=exec_price,
            difference_value=difference_value,
            difference_weight=difference_weight,
            journal_entry_id=journal_entry_id,
            notes=notes,
        )
        db.session.add(execution)

        order.executed_weight_main_karat = (order.executed_weight_main_karat or 0.0) + chunk
        order.remaining_weight_main_karat = max((order.total_weight_main_karat or 0.0) - order.executed_weight_main_karat, 0.0)
        if order.remaining_weight_main_karat <= 0.0001:
            order.status = 'closed'
            summary['orders_closed'].append(order.id)
        else:
            order.status = 'partially_closed'

        order.invoice.weight_closing_executed_weight = order.executed_weight_main_karat
        order.invoice.weight_closing_remaining_weight = order.remaining_weight_main_karat
        order.invoice.weight_closing_status = order.status

        remaining -= chunk
        summary['executions_created'] += 1
        summary['weight_consumed'] += chunk
        summary['difference_value_total'] += difference_value
        summary['difference_weight_total'] += difference_weight
        summary['orders_updated'].append(order.id)

    summary['cash_consumed'] = round(cash_spent, 2)
    db.session.flush()
    return summary


def reverse_weight_closing_executions_for_invoice(invoice_id, *, created_by=None):
    """Idempotent, standalone primitive: undoes every WeightClosingExecution
    row _auto_consume_weight_closing produced for this invoice, restoring
    each affected WeightClosingOrder (and its own source invoice's mirrored
    cache fields) to the state it was in before this invoice's consumption.

    Idempotent: a second call for the same invoice_id finds nothing left to
    reverse (the rows this call removes are exactly what makes it
    findable) and returns an empty summary — safe to call more than once.

    Auditable: logs one AuditLog entry with what was restored.

    Scoped to weight-closing bookkeeping only — does not create, delete, or
    touch any JournalEntry. A caller that also needs to reverse a
    JournalEntry (e.g. the settlement's own purchase-recognition entry)
    must do so separately; this primitive does not assume one exists.
    """
    executions = WeightClosingExecution.query.filter_by(source_invoice_id=invoice_id).all()
    summary = {'invoice_id': invoice_id, 'reversed_count': 0, 'orders_restored': []}
    if not executions:
        return summary

    for execution in executions:
        order = WeightClosingOrder.query.get(execution.order_id)
        if order is not None:
            order.executed_weight_main_karat = max(
                (order.executed_weight_main_karat or 0.0) - (execution.weight_main_karat or 0.0), 0.0
            )
            order.remaining_weight_main_karat = max(
                (order.total_weight_main_karat or 0.0) - order.executed_weight_main_karat, 0.0
            )
            if order.remaining_weight_main_karat <= 0.0001:
                order.status = 'closed'
            elif order.executed_weight_main_karat > 0.0001:
                order.status = 'partially_closed'
            else:
                order.status = 'open'
            if order.invoice is not None:
                order.invoice.weight_closing_executed_weight = order.executed_weight_main_karat
                order.invoice.weight_closing_remaining_weight = order.remaining_weight_main_karat
                order.invoice.weight_closing_status = order.status
            summary['orders_restored'].append(order.id)
        summary['reversed_count'] += 1
        db.session.delete(execution)

    db.session.flush()

    try:
        from models import AuditLog
        AuditLog.log_action(
            user_name=created_by or 'system',
            action='reverse_weight_closing_execution',
            entity_type='invoice',
            entity_id=invoice_id,
            details=json.dumps(summary, ensure_ascii=False),
            success=True,
        )
    except Exception:
        pass

    return summary
