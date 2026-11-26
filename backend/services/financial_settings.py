"""A financial (level-3) setting is changed by who holds its permission, with a reason (ADR-103).

One law for every route that writes one: the settings (PUT and PATCH), the
weight-closing settings, a VAT period, and the payroll policy (D15, the owner,
26 Nov 2026). A route names the level-3 keys a save would change -- a value
sent unchanged is not a change -- and asks:
  - refusal(keys): 403 financial_settings_permission, naming them, unless the
    user holds system.financial_settings (the system admin holds every code);
  - reason_refusal(keys, reason): 400 reason_required, naming them, when no
    reason is written.
None when the save may go on.
"""
from flask import g, jsonify

FINANCIAL_SETTINGS = 'system.financial_settings'


def holds() -> bool:
    user = getattr(g, 'current_user', None)
    return bool(user is not None and user.has_permission(FINANCIAL_SETTINGS))


def refusal(keys):
    keys = sorted(set(keys))
    if not keys or holds():
        return None
    return jsonify({'error': 'financial_settings_permission',
                    'message': 'هذه الإعدادات تمسّ الدفاتر: تغييرها لمن يحمل صلاحية «الإعدادات المالية والمحاسبية»',
                    'keys': keys}), 403


def reason_refusal(keys, reason):
    keys = sorted(set(keys))
    if not keys or str(reason or '').strip():
        return None
    return jsonify({'error': 'reason_required',
                    'message': 'هذه الإعدادات تمسّ الدفاتر: اكتب سبب التغيير', 'keys': keys}), 400
