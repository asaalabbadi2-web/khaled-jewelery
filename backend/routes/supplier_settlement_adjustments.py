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
from models import SupplierSettlementAdjustment, Supplier, db
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
