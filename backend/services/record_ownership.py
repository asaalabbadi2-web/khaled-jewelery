"""A user acts on their own records -- a seller's invoices, an employee's goals (ADR-036).

`invoices.edit` lets a seller correct, reject or delete an unposted invoice;
`invoices.edit_others` / `invoices.delete_others` extend it to everyone's. An
invoice is a seller's when its employee is the signed-in user's employee.
"""
from flask import g, jsonify


def refuse_unless_theirs(invoice, others_code: str):
    """None when the signed-in user may act on *invoice*; else a 403 response."""
    user = getattr(g, 'current_user', None)
    if user is None or getattr(user, 'is_admin', False) or user.has_permission(others_code):
        return None
    if invoice.employee_id is not None and invoice.employee_id == getattr(user, 'employee_id', None):
        return None
    return jsonify({
        'error': 'not_your_invoice',
        'message': 'هذه الفاتورة ليست من فواتيرك؛ يعدّلها أو يرفضها صاحبها أو المدير.',
    }), 403


SUPPLIER_INVOICE_TYPES = frozenset({'شراء', 'مرتجع شراء (مورد)', 'مرتجع شراء من مورد'})


def refuse_supplier_invoice_without_permission(invoice_type):
    """A supplier purchase or its return is the accountant's and the manager's,
    not the seller's (ADR-036): `invoices.supplier`. None when allowed."""
    if (invoice_type or '').strip() not in SUPPLIER_INVOICE_TYPES:
        return None
    user = getattr(g, 'current_user', None)
    if user is None or getattr(user, 'is_admin', False) or user.has_permission('invoices.supplier'):
        return None
    return jsonify({
        'error': 'permission_denied',
        'message': 'فواتير الموردين للمحاسب والمدير.',
        'required_permission': 'invoices.supplier',
    }), 403


def refuse_unless_self(employee_id, others_code: str = 'employees.bonuses'):
    """An employee acts on their own goals and achievements; another's needs
    *others_code* (ADR-036). None when allowed."""
    user = getattr(g, 'current_user', None)
    if user is None or getattr(user, 'is_admin', False) or user.has_permission(others_code):
        return None
    if employee_id is not None and employee_id == getattr(user, 'employee_id', None):
        return None
    return jsonify({'error': 'not_your_record', 'message': 'هذا ليس من سجلّك.'}), 403
