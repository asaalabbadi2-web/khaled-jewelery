"""What a reader may see, beyond whether they may read at all (ADR-036 R3, the owner 2 Oct 2026).

- A seller lists their own invoices; `invoices.view_others` lists everyone's.
- The cost and the profit are `costing.view`'s: a reader without it gets
  documents with no cost or profit field. The server still holds a sale
  under cost for approval (`below_cost`), whoever writes it.
- A seller reads the vouchers of their own invoice; `vouchers.view` reads all.
- Without `employees.view` the employee list is names only.
- The approvals bell counts for those who approve.
"""
import re

from flask import g, jsonify, request

COST_KEY = re.compile(r'(cost|profit)', re.IGNORECASE)


def _user():
    return getattr(g, 'current_user', None)


def holds(code: str) -> bool:
    user = _user()
    return user is not None and (getattr(user, 'is_admin', False) or user.has_permission(code))


def scope_invoices_to_reader(query):
    """The invoice list for the reader: their own unless they hold invoices.view_others."""
    from models import Invoice
    if holds('invoices.view_others'):
        return query
    employee_id = getattr(_user(), 'employee_id', None)
    return query.filter(Invoice.employee_id == employee_id) if employee_id else query.filter(Invoice.id == -1)


def without_cost(obj):
    """*obj* as the reader may see it: every cost and profit field dropped without costing.view."""
    if holds('costing.view'):
        return obj
    return _strip(obj)


def _strip(obj):
    if isinstance(obj, dict):
        return {k: _strip(v) for k, v in obj.items() if not COST_KEY.search(str(k))}
    if isinstance(obj, list):
        return [_strip(v) for v in obj]
    return obj


def refuse_voucher_list_unless_allowed():
    """vouchers.view lists all; a seller lists the vouchers of their own invoice. None when allowed."""
    if holds('vouchers.view'):
        return None
    if (request.args.get('reference_type') or '').strip().lower() == 'invoice':
        from models import Invoice
        invoice = Invoice.query.get(request.args.get('reference_id', type=int) or 0)
        if invoice is not None:
            from services.record_ownership import refuse_unless_theirs
            if refuse_unless_theirs(invoice, 'invoices.view_others') is None:
                return None
    return jsonify({'error': 'permission_denied', 'message': 'ليس لديك صلاحية لعرض السندات',
                    'required_permission': 'vouchers.view'}), 403


def is_approver() -> bool:
    return any(holds(c) for c in ('invoices.approve', 'journal.post', 'audit.view'))
