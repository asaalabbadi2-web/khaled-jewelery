"""Weight closing settings, and the reversal of the stored executions the old
engine left (ADR-048 phase 3a: the position is derived from the books now)."""
from __future__ import annotations

import json

from models import (
    db,
    Settings,
    WeightClosingExecution,
    WeightClosingOrder,
)


DEFAULT_WEIGHT_CLOSING_SETTINGS = {
    # No main karat here: it is the settings' own (Settings.main_karat), one place.
    'price_source': 'live',
    'enabled': True,
    'allow_override': True,
    'shift_close_cash_deficit_threshold': 50.0,
    'shift_close_gold_pure_deficit_threshold_grams': 0.10,
    'order_number_prefix': 'WCO',
    'reservation_code_prefix': 'RES',
    'cash_safe_box_id': None,
    # The manager's card raises an alert when the oldest sale waits longer than
    # this (the owner, 16 Oct 2026: 7 days; policy -- his to change).
    'position_oldest_alert_days': 7,
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


def reverse_weight_closing_executions_for_invoice(invoice_id, *, created_by=None):
    """Idempotent, standalone primitive: undoes every WeightClosingExecution
    row the old engine (_auto_consume_weight_closing, removed in ADR-048
    phase 3a) produced for this invoice, restoring
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
