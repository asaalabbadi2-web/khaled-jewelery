"""HTTP layer for Supplier Settlement Adjustments (SAD) — ADR-025.

This module is a thin controller. It owns authentication, authorization,
request validation, service invocation, and HTTP error mapping — nothing else.
Every accounting decision (direction, amounts, accounts, limits, invariants)
belongs to SupplierSettlementAdjustmentService and stays there.

Two rules shape the request handling:

  1. The client never supplies accounting inputs. Direction, amounts, GL
     accounts, policy, voucher and journal links are derived by the service
     from live supplier balances. A request carrying any of them is rejected
     rather than silently ignored, so a caller cannot believe it controlled a
     value that it did not.

  2. Attribution and authority come from the authenticated identity. `is_manager`
     in particular is derived server-side from the permission system — it is
     never read from the request body.
"""

from __future__ import annotations

from datetime import datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_auth, require_permission
from models import (
    SupplierSettlementAdjustment,
    SupplierSettlementPolicy,
    SupplierSettlementReasonLimit,
    Supplier,
    db,
)
from services.supplier_settlement_adjustment_service import (
    ManagerApprovalRequiredError,
    MissingAccountingMappingError,
    NotEligibleError,
    SettlementInvariantViolation,
    SnapshotMismatchError,
    SupplierAccountReviewRequiredError,
    SupplierSettlementAdjustmentService,
)

supplier_settlement_adjustments_bp = Blueprint('supplier_settlement_adjustments', __name__)

_service = SupplierSettlementAdjustmentService()

# Fields the client may send when creating a draft. Everything else — amounts,
# direction, accounts, policy, is_manager — is derived server-side.
_CREATE_ALLOWED_FIELDS = {'reason_code', 'note'}

# Named explicitly so the rejection message can say what went wrong instead of
# a generic "unknown field".
_CLIENT_FORBIDDEN_FIELDS = {
    'is_manager', 'direction', 'amount', 'amount_cash', 'posted_amount_cash',
    'posted_amount_weight', 'account_id', 'policy_id', 'voucher_id',
    'journal_entry_id', 'approved_by', 'posted_by', 'reversed_by',
    'cancelled_by', 'created_by', 'status',
}

# The elevated bar for reason_code=OTHER. Not a new role: a permission code in
# the existing registry, granted to the `manager` role and withheld from
# `accountant`. System admins bypass permissions as they do everywhere.
_APPROVE_OTHER_PERMISSION = 'supplier_settlement_adjustments.approve_other'


# ── Helpers ──────────────────────────────────────────────────────────────────

def _actor() -> str:
    """The authenticated user, for audit attribution. Never from the request."""
    user = getattr(g, 'current_user', None)
    return getattr(user, 'username', None) or 'system'


def _is_manager_approval() -> bool:
    """Derive manager authority from the authenticated identity alone."""
    user = getattr(g, 'current_user', None)
    if user is None:
        return False
    if bool(getattr(user, 'is_admin', False)):
        return True
    try:
        return bool(user.has_permission(_APPROVE_OTHER_PERMISSION))
    except Exception:
        return False


def _now() -> datetime:
    """ADR-015 boundary: the clock is read here and injected into the service."""
    return datetime.now()


def _payload() -> dict:
    return request.get_json(silent=True) or {}


def _reject_client_controlled_fields(data: dict):
    """Refuse requests that try to set values the service must decide."""
    offending = sorted(set(data) & _CLIENT_FORBIDDEN_FIELDS)
    if not offending:
        return None
    return jsonify({
        'success': False,
        'message': (
            'لا يجوز للعميل تحديد هذه القيم — يشتقها النظام من رصيد المورد '
            'الحي والسياسة المحاسبية والهوية المصادَّقة: ' + '، '.join(offending)
        ),
        'error': 'client_controlled_field_rejected',
        'fields': offending,
    }), 400


def _error(exc: Exception):
    """Map a domain error to the ERP's JSON error shape and HTTP status.

    Status conventions follow the existing ERP routes: 409 for state conflicts,
    404 for missing records, 403 for authority, 400 for everything else the
    caller can act on, 500 only for an integrity failure that must never happen.
    """
    if isinstance(exc, SupplierAccountReviewRequiredError):
        body = exc.to_dict()
        body['success'] = False
        return jsonify(body), 409

    if isinstance(exc, SnapshotMismatchError):
        return jsonify({
            'success': False,
            'message': str(exc),
            'error': 'snapshot_mismatch',
            'action_required': 'recalculate',
        }), 409

    if isinstance(exc, NotEligibleError):
        return jsonify({
            'success': False,
            'message': str(exc),
            'error': 'not_eligible',
            'failed_checks': [
                {'name': c.name, 'detail': c.detail} for c in exc.failed_checks
            ],
        }), 409

    if isinstance(exc, ManagerApprovalRequiredError):
        return jsonify({
            'success': False,
            'message': str(exc),
            'error': 'manager_approval_required',
            'required_permission': _APPROVE_OTHER_PERMISSION,
        }), 403

    if isinstance(exc, MissingAccountingMappingError):
        return jsonify({
            'success': False,
            'message': str(exc),
            'error': 'missing_accounting_mapping',
        }), 400

    if isinstance(exc, SettlementInvariantViolation):
        # The service already rolled the work back by raising. Surfacing this as
        # 500 is deliberate: it means the ledger did not move as intended.
        return jsonify({
            'success': False,
            'message': str(exc),
            'error': 'settlement_invariant_violation',
        }), 500

    return jsonify({
        'success': False,
        'message': str(exc),
        'error': 'invalid_request',
    }), 400


def _get_or_404(sad_id: int):
    sad = SupplierSettlementAdjustment.query.get(sad_id)
    if sad is None:
        return None, (jsonify({
            'success': False,
            'message': f'تسوية فرق المورد #{sad_id} غير موجودة',
            'error': 'not_found',
        }), 404)
    return sad, None


def _run(operation):
    """Invoke a service call, own the transaction, and map failures.

    The service flushes but never commits — committing here keeps one commit
    boundary per HTTP request, and a rollback on any failure keeps the refusal
    write-free.
    """
    try:
        result = operation()
        db.session.commit()
        return result, None
    except Exception as exc:
        db.session.rollback()
        return None, _error(exc)


# ── Supplier-scoped ──────────────────────────────────────────────────────────

@supplier_settlement_adjustments_bp.route(
    '/suppliers/<int:supplier_id>/settlement-adjustments', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.create')
def create_settlement_adjustment(supplier_id):
    """Create a draft. The client chooses the reason; the ledger decides the rest."""
    data = _payload()

    rejection = _reject_client_controlled_fields(data)
    if rejection:
        return rejection

    unknown = sorted(set(data) - _CREATE_ALLOWED_FIELDS)
    if unknown:
        return jsonify({
            'success': False,
            'message': 'حقول غير مدعومة: ' + '، '.join(unknown),
            'error': 'unsupported_field',
            'fields': unknown,
        }), 400

    supplier = Supplier.query.get(supplier_id)
    if supplier is None:
        return jsonify({
            'success': False,
            'message': f'المورد #{supplier_id} غير موجود',
            'error': 'not_found',
        }), 404

    sad, error = _run(lambda: _service.create_draft(
        supplier=supplier,
        reason_code=(data.get('reason_code') or '').strip(),
        note=data.get('note'),
        created_by=_actor(),
        now=_now(),
    ))
    if error:
        return error

    return jsonify({
        'success': True,
        'message': 'تم إنشاء مسودة تسوية فرق حساب المورد',
        'adjustment': sad.to_dict(),
    }), 201


@supplier_settlement_adjustments_bp.route(
    '/suppliers/<int:supplier_id>/settlement-adjustments', methods=['GET'])
@require_auth
@require_permission('supplier_settlement_adjustments.view')
def list_settlement_adjustments(supplier_id):
    """List a supplier's adjustments, newest first. Optional ?status= filter."""
    query = (
        SupplierSettlementAdjustment.query
        .filter(SupplierSettlementAdjustment.supplier_id == supplier_id)
    )

    status = (request.args.get('status') or '').strip()
    if status:
        query = query.filter(SupplierSettlementAdjustment.status == status)

    rows = query.order_by(SupplierSettlementAdjustment.id.desc()).all()
    return jsonify({
        'success': True,
        'supplier_id': supplier_id,
        'count': len(rows),
        'adjustments': [r.to_dict() for r in rows],
    }), 200


# ── Document-scoped ──────────────────────────────────────────────────────────

@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>', methods=['GET'])
@require_auth
@require_permission('supplier_settlement_adjustments.view')
def get_settlement_adjustment(sad_id):
    sad, error = _get_or_404(sad_id)
    if error:
        return error
    return jsonify({'success': True, 'adjustment': sad.to_dict()}), 200


@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>/preview', methods=['GET'])
@require_auth
@require_permission('supplier_settlement_adjustments.view')
def preview_settlement_adjustment(sad_id):
    """What post() would decide right now. Reads the ledger, writes nothing.

    A sub-resource rather than extra keys on GET /<id> for two reasons: the
    verdict costs several aggregate queries that a caller fetching the document
    should not pay for, and the existing response shape stays untouched for the
    clients already parsing it.

    Deliberately not routed through _run(): that helper commits, and there is
    nothing here to commit. The session is rolled back on both paths so a read
    can never leave an open transaction behind.
    """
    sad, error = _get_or_404(sad_id)
    if error:
        return error

    try:
        preview = _service.preview(sad=sad, now=_now())
        body = preview.to_dict()
    except Exception as exc:
        db.session.rollback()
        return _error(exc)
    finally:
        # No write is intended, and none is allowed to escape by accident.
        db.session.rollback()

    return jsonify({'success': True, 'preview': body}), 200


@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>/recalculate', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.create')
def recalculate_settlement_adjustment(sad_id):
    """Re-read the live balance into the draft's snapshot. Drafts only."""
    sad, error = _get_or_404(sad_id)
    if error:
        return error

    _, error = _run(lambda: _service.refresh_snapshot(sad=sad, now=_now()))
    if error:
        return error

    return jsonify({
        'success': True,
        'message': 'تم إعادة حساب الرصيد وتحديث اللقطة',
        'adjustment': sad.to_dict(),
    }), 200


@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>/approve', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.approve')
def approve_settlement_adjustment(sad_id):
    """Approve a draft. Authority for reason_code=OTHER is checked server-side."""
    rejection = _reject_client_controlled_fields(_payload())
    if rejection:
        return rejection

    sad, error = _get_or_404(sad_id)
    if error:
        return error

    _, error = _run(lambda: _service.approve(
        sad=sad,
        approved_by=_actor(),
        is_manager=_is_manager_approval(),
        now=_now(),
    ))
    if error:
        return error

    return jsonify({
        'success': True,
        'message': 'تم اعتماد التسوية',
        'adjustment': sad.to_dict(),
    }), 200


@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>/post', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.post')
def post_settlement_adjustment(sad_id):
    """Post the adjustment through the canonical Voucher pipeline."""
    rejection = _reject_client_controlled_fields(_payload())
    if rejection:
        return rejection

    sad, error = _get_or_404(sad_id)
    if error:
        return error

    _, error = _run(lambda: _service.post(
        sad=sad,
        posted_by=_actor(),
        now=_now(),
    ))
    if error:
        return error

    return jsonify({
        'success': True,
        'message': 'تم ترحيل التسوية',
        'adjustment': sad.to_dict(),
    }), 200


@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>/reverse', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.reverse')
def reverse_settlement_adjustment(sad_id):
    """Reverse a posted adjustment by posting an opposite one."""
    data = _payload()

    rejection = _reject_client_controlled_fields(data)
    if rejection:
        return rejection

    reason = (data.get('reason') or '').strip()
    if not reason:
        return jsonify({
            'success': False,
            'message': 'سبب العكس إلزامي',
            'error': 'reason_required',
        }), 400

    sad, error = _get_or_404(sad_id)
    if error:
        return error

    reversal, error = _run(lambda: _service.reverse(
        sad=sad,
        reversed_by=_actor(),
        reason=reason,
        now=_now(),
    ))
    if error:
        return error

    return jsonify({
        'success': True,
        'message': 'تم عكس التسوية بوثيقة جديدة',
        'adjustment': sad.to_dict(),
        'reversal': reversal.to_dict(),
    }), 201


@supplier_settlement_adjustments_bp.route(
    '/supplier-settlement-adjustments/<int:sad_id>/cancel', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.cancel')
def cancel_settlement_adjustment(sad_id):
    """Cancel a draft or approved adjustment. Posted ones must be reversed."""
    data = _payload()

    rejection = _reject_client_controlled_fields(data)
    if rejection:
        return rejection

    reason = (data.get('reason') or '').strip()
    if not reason:
        return jsonify({
            'success': False,
            'message': 'سبب الإلغاء إلزامي',
            'error': 'reason_required',
        }), 400

    sad, error = _get_or_404(sad_id)
    if error:
        return error

    _, error = _run(lambda: _service.cancel(
        sad=sad,
        cancelled_by=_actor(),
        reason=reason,
        now=_now(),
    ))
    if error:
        return error

    return jsonify({
        'success': True,
        'message': 'تم إلغاء التسوية',
        'adjustment': sad.to_dict(),
    }), 200


# ======================================================================
# Policy — the limits themselves
# ======================================================================

@supplier_settlement_adjustments_bp.route('/supplier-settlement-policy', methods=['GET'])
@require_auth
@require_permission('supplier_settlement_adjustments.view')
def get_supplier_settlement_policy():
    """The limits in force, with each reason's own ceilings.

    These numbers are POLICY — the model says finance changes them without a
    deploy — but until now there was no surface to change them through, so the
    only way in was hand-written SQL. That is also why a documented waiver was
    stuck behind a 5 SAR rounding limit: nobody could raise it.

    Reasons with no row of their own report the policy's global limits, which is
    exactly what governs them.
    """
    policy = SupplierSettlementPolicy.in_effect_at(datetime.now())
    if policy is None:
        return jsonify({
            'success': True, 'policy': None,
            'message': 'لا توجد سياسة تسوية سارية — لا يمكن إجراء أي تسوية قبل تحديدها',
        }), 200

    payload = policy.to_dict()
    payload['reason_limits'] = []
    for code in sorted(SupplierSettlementAdjustment.VALID_REASON_CODES):
        limits = policy.limits_for_reason(code)
        always = code in SupplierSettlementAdjustment.REASONS_REQUIRING_MANAGER_APPROVAL
        payload['reason_limits'].append({
            'reason_code': code,
            # Effective values: what actually governs this reason right now,
            # whether it came from its own row or from the global fallback. The
            # screen shows the number in force, never a blank the reader has to
            # resolve themselves.
            'tolerance_cash': limits.tolerance_cash,
            'tolerance_weight_main_karat': limits.tolerance_weight,
            'review_threshold_cash': limits.review_threshold_cash,
            'period_cap_cash': limits.period_cap_cash,
            'period_cap_weight_main_karat': limits.period_cap_weight,
            'requires_manager_approval': bool(
                limits.requires_manager_approval
                if limits.requires_manager_approval is not None
                else always
            ),
            'is_explicit': limits.is_explicit,
            'always_requires_manager': always,
        })
    return jsonify({'success': True, 'policy': payload}), 200


@supplier_settlement_adjustments_bp.route('/supplier-settlement-policy', methods=['POST'])
@require_auth
@require_permission('supplier_settlement_adjustments.approve')
def create_supplier_settlement_policy():
    """Put new limits into force, by CLOSING the current row and inserting one.

    Never an UPDATE. A posted settlement froze the policy id it was judged
    against, so editing that row in place would rewrite the basis of an
    accounting decision already taken. The model states the rule; this endpoint
    is what makes following it possible without SQL.

    Body: the five global limits, plus optional per-reason entries carrying
    {reason_code, tolerance_cash, tolerance_weight_main_karat} and, optionally,
    {review_threshold_cash, period_cap_cash, period_cap_weight_main_karat,
    requires_manager_approval}. A per-reason ceiling left out — or sent null —
    inherits the global one; a reason left out entirely inherits all five.
    """
    data = request.get_json(silent=True) or {}

    required = (
        'tolerance_cash', 'tolerance_weight',
        'period_cap_cash', 'period_cap_weight', 'review_threshold_cash',
    )
    missing = [k for k in required if data.get(k) is None]
    if missing:
        return jsonify({
            'success': False, 'error': 'missing_fields',
            'message': f'الحدود المطلوبة ناقصة: {", ".join(missing)}',
        }), 400

    try:
        values = {k: float(data[k]) for k in required}
    except (TypeError, ValueError):
        return jsonify({
            'success': False, 'error': 'invalid_numbers',
            'message': 'كل الحدود يجب أن تكون أرقامًا',
        }), 400
    if any(v < 0 for v in values.values()):
        return jsonify({
            'success': False, 'error': 'negative_limit',
            'message': 'لا يمكن أن يكون أي حد سالبًا',
        }), 400

    # Same defect class as the per-reason check below: a per-operation tolerance
    # above its own monthly cap can never be reached, because the cap refuses
    # first. It is checked here too rather than only per-reason, since the globals
    # govern every reason that has no row of its own.
    for tolerance_key, cap_key, label in (
        ('tolerance_cash', 'period_cap_cash', 'النقد'),
        ('tolerance_weight', 'period_cap_weight', 'الوزن'),
    ):
        if values[tolerance_key] > values[cap_key]:
            return jsonify({
                'success': False, 'error': 'unreachable_limit',
                'message': (
                    f'حد العملية العام لـ{label} ({values[tolerance_key]}) أكبر من '
                    f'السقف الشهري ({values[cap_key]}) — لن يُستخدم أبدًا لأن السقف '
                    'يرفض أولًا'
                ),
            }), 400

    reason_rows = data.get('reason_limits') or []
    if not isinstance(reason_rows, list):
        return jsonify({
            'success': False, 'error': 'invalid_reason_limits',
            'message': 'reason_limits يجب أن تكون قائمة',
        }), 400
    parsed = []
    for entry in reason_rows:
        if not isinstance(entry, dict):
            return jsonify({
                'success': False, 'error': 'invalid_reason_limits',
                'message': 'كل عنصر في reason_limits يجب أن يكون كائنًا',
            }), 400
        code = str(entry.get('reason_code') or '')
        if code not in SupplierSettlementAdjustment.VALID_REASON_CODES:
            return jsonify({
                'success': False, 'error': 'invalid_reason_code',
                'message': f'سبب غير صالح: {code}',
            }), 400
        # The two tolerances are required; the other three gates are optional
        # overrides, and absent means "keep using the global" — which is why they
        # are nullable columns rather than copies of the policy's numbers.
        fields = {}
        try:
            fields['tolerance_cash'] = float(entry['tolerance_cash'])
            fields['tolerance_weight_main_karat'] = float(
                entry['tolerance_weight_main_karat'])
        except (KeyError, TypeError, ValueError):
            return jsonify({
                'success': False, 'error': 'invalid_reason_limits',
                'message': f'حدود السبب {code} يجب أن تكون أرقامًا',
            }), 400
        for optional in ('review_threshold_cash', 'period_cap_cash',
                         'period_cap_weight_main_karat'):
            raw = entry.get(optional)
            if raw is None:
                fields[optional] = None
                continue
            try:
                fields[optional] = float(raw)
            except (TypeError, ValueError):
                return jsonify({
                    'success': False, 'error': 'invalid_reason_limits',
                    'message': f'حد {optional} للسبب {code} يجب أن يكون رقمًا',
                }), 400
        if any(v is not None and v < 0 for v in fields.values()):
            return jsonify({
                'success': False, 'error': 'negative_limit',
                'message': f'حدود السبب {code} لا يمكن أن تكون سالبة',
            }), 400

        # A per-operation tolerance above the monthly cap can never be reached —
        # the cap refuses first. Silently accepting it would show finance a limit
        # the mechanism ignores.
        cap_cash = fields['period_cap_cash']
        if cap_cash is not None and fields['tolerance_cash'] > cap_cash:
            return jsonify({
                'success': False, 'error': 'unreachable_limit',
                'message': (
                    f'حد العملية للسبب {code} ({fields["tolerance_cash"]}) أكبر من '
                    f'سقفه الشهري ({cap_cash}) — لن يُستخدم أبدًا لأن السقف يرفض أولًا'
                ),
            }), 400
        cap_weight = fields['period_cap_weight_main_karat']
        if cap_weight is not None and fields['tolerance_weight_main_karat'] > cap_weight:
            return jsonify({
                'success': False, 'error': 'unreachable_limit',
                'message': (
                    f'حد وزن العملية للسبب {code} '
                    f'({fields["tolerance_weight_main_karat"]}) أكبر من سقفه الشهري '
                    f'({cap_weight}) — لن يُستخدم أبدًا لأن السقف يرفض أولًا'
                ),
            }), 400

        fields['requires_manager_approval'] = bool(
            entry.get('requires_manager_approval'))
        parsed.append((code, fields))

    now = datetime.now()
    actor = _actor()
    try:
        current = SupplierSettlementPolicy.in_effect_at(now)
        if current is not None:
            current.effective_to = now

        policy = SupplierSettlementPolicy(
            effective_from=now,
            notes=(data.get('notes') or None),
            created_by=actor,
            **values,
        )
        db.session.add(policy)
        db.session.flush()

        for code, fields in parsed:
            db.session.add(SupplierSettlementReasonLimit(
                policy_id=policy.id, reason_code=code, **fields,
            ))
        db.session.commit()
    except Exception as exc:
        db.session.rollback()
        return jsonify({
            'success': False, 'error': 'policy_not_created', 'message': str(exc),
        }), 400

    return jsonify({
        'success': True,
        'message': 'تم تحديد حدود التسوية الجديدة، وأُغلقت السابقة',
        'policy_id': policy.id,
        'closed_policy_id': current.id if current is not None else None,
    }), 201
