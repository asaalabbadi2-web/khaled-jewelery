"""HTTP layer for Supplier Gold Advance & Allocation — Phase 15C.

Thin controller: owns auth, request validation, service invocation, and HTTP
error mapping. Every matching/bookkeeping decision belongs to
GoldAllocationService and stays there — this module never computes a
balance or decides FIFO order itself.

Read endpoints (list/detail) exist to give the manual-override action
somewhere to find its candidate ids from: which Advances are still open for
a supplier, which of an invoice's Gold Obligations are still open. The
override itself is the only write endpoint — creating an Advance or an
Invoice Gold Obligation happens through the existing voucher/invoice routes
(reference_type='gold_advance', and regular 'شراء' posting respectively),
never here.
"""
from __future__ import annotations

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_auth, require_permission
from models import GoldAllocation, Invoice, InvoiceGoldObligation, SupplierGoldAdvance, db
from services.gold_allocation_service import GoldAllocationService

gold_advances_bp = Blueprint('gold_advances', __name__)

_service = GoldAllocationService()


def _actor() -> str:
    user = getattr(g, 'current_user', None)
    return getattr(user, 'username', None) or 'system'


@gold_advances_bp.route('/gold-advances', methods=['GET'])
@require_auth
@require_permission('gold_advances.view')
def list_gold_advances():
    """List Supplier Gold Advances. ?supplier_id= filters to one supplier;
    ?open_only=1 (default) shows only advances with weight left to apply."""
    query = SupplierGoldAdvance.query

    supplier_id = request.args.get('supplier_id', type=int)
    if supplier_id is not None:
        query = query.filter(SupplierGoldAdvance.supplier_id == supplier_id)

    open_only = request.args.get('open_only', default='1') not in ('0', 'false', 'False')
    if open_only:
        query = query.filter(SupplierGoldAdvance.weight_remaining_main_karat > 0.005)

    advances = query.order_by(SupplierGoldAdvance.created_at.asc()).all()
    return jsonify({
        'success': True,
        'advances': [a.to_dict() for a in advances],
    }), 200


@gold_advances_bp.route('/gold-advances/<int:advance_id>', methods=['GET'])
@require_auth
@require_permission('gold_advances.view')
def get_gold_advance(advance_id):
    advance = SupplierGoldAdvance.query.get(advance_id)
    if advance is None:
        return jsonify({
            'success': False,
            'message': f'دفعة الذهب المقدمة #{advance_id} غير موجودة',
            'error': 'not_found',
        }), 404

    allocations = GoldAllocation.query.filter_by(advance_id=advance.id).all()
    payload = advance.to_dict()
    payload['allocations'] = [a.to_dict() for a in allocations]
    return jsonify({'success': True, 'advance': payload}), 200


@gold_advances_bp.route('/invoices/<int:invoice_id>/gold-obligations', methods=['GET'])
@require_auth
@require_permission('gold_advances.view')
def list_invoice_gold_obligations(invoice_id):
    invoice = Invoice.query.get(invoice_id)
    if invoice is None:
        return jsonify({
            'success': False,
            'message': f'الفاتورة #{invoice_id} غير موجودة',
            'error': 'not_found',
        }), 404

    obligations = InvoiceGoldObligation.query.filter_by(invoice_id=invoice.id).all()
    result = []
    for ob in obligations:
        d = ob.to_dict()
        d['allocations'] = [
            a.to_dict() for a in GoldAllocation.query.filter_by(obligation_id=ob.id).all()
        ]
        result.append(d)

    return jsonify({'success': True, 'obligations': result}), 200


@gold_advances_bp.route('/gold-advances/<int:advance_id>/allocate', methods=['POST'])
@require_auth
@require_permission('gold_advances.allocate')
def manual_allocate_gold_advance(advance_id):
    """Explicit human override: redirect this much of this Advance to a
    specific Invoice Gold Obligation, bypassing FIFO ordering. Body:
    {"obligation_id": int, "weight_main_karat": float}.
    """
    data = request.get_json(silent=True) or {}

    obligation_id = data.get('obligation_id')
    weight_main_karat = data.get('weight_main_karat')
    if not obligation_id or weight_main_karat is None:
        return jsonify({
            'success': False,
            'message': 'obligation_id و weight_main_karat مطلوبان',
            'error': 'missing_fields',
        }), 400

    try:
        allocation = _service.manual_allocate(
            advance_id=advance_id,
            obligation_id=int(obligation_id),
            weight_main_karat=float(weight_main_karat),
        )
    except ValueError as exc:
        db.session.rollback()
        code = str(exc).split(':', 1)[0]
        return jsonify({
            'success': False,
            'message': str(exc),
            'error': code,
        }), 400

    db.session.commit()
    return jsonify({
        'success': True,
        'message': 'تم تخصيص الذهب يدويًا',
        'allocation': allocation.to_dict(),
    }), 201
