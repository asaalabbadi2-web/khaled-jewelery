"""Who creates does not approve; the accountant approves within a limit (ADR-036 R4, the owner 2 Oct 2026).

A manual voucher or a manual journal entry is approved -- posted -- by someone
other than its creator. The manager approves a voucher (`vouchers.approve`);
the accountant approves another's within the settings' limit
(`vouchers.approve_within_limit`; cash in riyals, gold in grams of the main
karat; 0 = nothing -- the owner's starting value). The system admin (the
owner) is not held. Who created and who approved are the session's user,
never text from the request.
"""
from flask import g, jsonify


def actor() -> str:
    """The signed-in user's name, for the record. Never from the request."""
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


def _user():
    return getattr(g, 'current_user', None)


def _is_owner(user) -> bool:
    return bool(user is not None and getattr(user, 'is_admin', False))


def may_approve_own() -> bool:
    """Only the system admin approves what they created -- e.g. auto-approval at creation."""
    return _is_owner(_user())


def _own_document():
    return jsonify({'error': 'own_document',
                    'message': 'لا يعتمد المستند من أنشأه؛ يعتمده غيرك (فصل المهام).'}), 403


def _gold_grams_main(voucher) -> float:
    from pricing.karat_service import convert_to_main_karat
    total = 0.0
    lines = getattr(voucher, 'account_lines', None)
    for line in (lines.all() if hasattr(lines, 'all') else lines or []):
        if (line.amount_type or '') == 'gold' and (line.line_type or '') == 'debit':
            total += float(convert_to_main_karat(float(line.amount or 0.0), float(line.karat or 0.0)) or 0.0)
    return total


def refuse_unless_may_approve_voucher(voucher):
    """None when the signed-in user may approve *voucher*; else a 403 response."""
    user = _user()
    if _is_owner(user):
        return None
    if user is None:
        return jsonify({'error': 'permission_denied', 'message': 'يلزم تسجيل الدخول'}), 401
    if (voucher.created_by or '') == getattr(user, 'username', None):
        return _own_document()
    if user.has_permission('vouchers.approve'):
        return None
    if user.has_permission('vouchers.approve_within_limit'):
        from core.settings import _get_settings_singleton
        row = _get_settings_singleton(create_if_missing=False)
        cash_limit = float(getattr(row, 'accountant_approval_limit_cash', 0.0) or 0.0)
        gold_limit = float(getattr(row, 'accountant_approval_limit_gold_grams', 0.0) or 0.0)
        cash = float(voucher.amount_cash or 0.0)
        gold = _gold_grams_main(voucher)
        if (cash_limit > 0 or gold_limit > 0) and cash <= cash_limit + 1e-9 and gold <= gold_limit + 1e-9:
            return None
        return jsonify({'error': 'over_approval_limit',
                        'message': f'السند فوق حدّ اعتماد المحاسب ({cash_limit:g} ريال، {gold_limit:g} غ)؛ يعتمده المدير.',
                        'limit_cash': cash_limit, 'limit_gold_grams': gold_limit}), 403
    return jsonify({'error': 'permission_denied', 'message': 'ليس لديك صلاحية اعتماد السندات',
                    'required_permission': 'vouchers.approve'}), 403


def refuse_unless_may_post_entry(entry):
    """A manual entry is posted by someone other than its creator (the owner excepted)."""
    user = _user()
    if _is_owner(user) or user is None:
        return None
    if entry.created_by and entry.created_by == getattr(user, 'username', None):
        return _own_document()
    return None
