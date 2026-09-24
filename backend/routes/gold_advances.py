"""HTTP layer for Supplier Gold Advance & Allocation — Phase 16C.

Thin controller: owns auth, request validation, service invocation, and HTTP
error mapping. Every derived figure belongs to gold_allocation_service and
stays there — this module never computes a balance itself.

Read endpoints exist to give the allocate action somewhere to find its
candidate ids: which Advances still have unallocated weight for a supplier,
which of an invoice's gold obligations still have unattributed weight, and
(the reconciliation endpoint) how a supplier's whole gold position breaks
down. Allocation is the only write endpoint — creating an Advance or an
obligation happens through the existing voucher/invoice routes
(reference_type='gold_advance', and regular 'شراء' posting respectively),
never here.

Naming discipline (Phase 16C contract): an obligation's figure is reported as
attributed_remaining_main_karat, never `remaining`. It is gross minus only
what can be evidenced against this specific invoice, so it is an upper bound
on what is owed, not the answer — the authoritative answer is the supplier's
GL position, which /suppliers/<id>/gold-reconciliation reports alongside the
named unattributed residual.
"""
from __future__ import annotations

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_auth, require_permission
from models import (
    GoldAllocation,
    Invoice,
    InvoiceGoldObligation,
    Supplier,
    SupplierGoldAdvance,
    db,
)
from services.gold_allocation_service import (
    GoldAllocationService,
    WEIGHT_EPSILON,
    advance_remaining,
    obligation_attributed_remaining,
    obligation_attributed_settlement,
    reconcile_supplier,
)

gold_advances_bp = Blueprint('gold_advances', __name__)

_service = GoldAllocationService()


def _actor() -> str:
    user = getattr(g, 'current_user', None)
    return getattr(user, 'username', None) or 'system'


def _advance_payload(advance: SupplierGoldAdvance) -> dict:
    payload = advance.to_dict()
    payload['remaining_main_karat'] = advance_remaining(advance)
    return payload


def _obligation_payload(obligation: InvoiceGoldObligation) -> dict:
    payload = obligation.to_dict()
    payload['attributed_settlement_main_karat'] = obligation_attributed_settlement(obligation)
    payload['attributed_remaining_main_karat'] = obligation_attributed_remaining(obligation)
    return payload


@gold_advances_bp.route('/gold-advances', methods=['GET'])
@require_auth
@require_permission('gold_advances.view')
def list_gold_advances():
    """List Supplier Gold Advances. ?supplier_id= filters to one supplier;
    ?open_only=1 (default) shows only advances with unallocated weight left.

    open_only is applied in Python rather than SQL because remaining is
    derived from GoldAllocation, not stored — the row count here is tiny
    (Phase 16B: zero real advances exist yet) so there is nothing to optimize.
    """
    query = SupplierGoldAdvance.query

    supplier_id = request.args.get('supplier_id', type=int)
    if supplier_id is not None:
        query = query.filter(SupplierGoldAdvance.supplier_id == supplier_id)

    advances = query.order_by(SupplierGoldAdvance.created_at.asc()).all()
    payloads = [_advance_payload(a) for a in advances]

    open_only = request.args.get('open_only', default='1') not in ('0', 'false', 'False')
    if open_only:
        payloads = [p for p in payloads if p['remaining_main_karat'] > WEIGHT_EPSILON]

    return jsonify({'success': True, 'advances': payloads}), 200


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
    payload = _advance_payload(advance)
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
        payload = _obligation_payload(ob)
        payload['allocations'] = [
            a.to_dict() for a in GoldAllocation.query.filter_by(obligation_id=ob.id).all()
        ]
        result.append(payload)

    return jsonify({'success': True, 'obligations': result}), 200


@gold_advances_bp.route('/suppliers/<int:supplier_id>/gold-reconciliation', methods=['GET'])
@require_auth
@require_permission('gold_advances.view')
def get_supplier_gold_reconciliation(supplier_id):
    """The contract's identity for one supplier, in main-karat-equivalent:

        gross_obligation - attributed_settlement - unattributed_settlement
            == gl_position

    unattributed_settlement is reported explicitly so that the gap between
    invoice-level records and the real GL position is a named quantity rather
    than an unexplained discrepancy someone is tempted to close by inventing
    an allocation.
    """
    supplier = Supplier.query.get(supplier_id)
    if supplier is None:
        return jsonify({
            'success': False,
            'message': f'المورد #{supplier_id} غير موجود',
            'error': 'not_found',
        }), 404

    return jsonify({
        'success': True,
        'reconciliation': reconcile_supplier(supplier),
    }), 200


@gold_advances_bp.route('/suppliers/<int:supplier_id>/open-gold-obligations', methods=['GET'])
@require_auth
@require_permission('gold_advances.view')
def list_supplier_open_gold_obligations(supplier_id):
    """The invoices an employee can pick when declaring a gold payment.

    Exists because attribution must be a CHOICE, and a choice needs visible
    candidates: Phase 16B found employees faced two or more plausible invoices
    61% of the time and 21 or more in 19 cases, with nothing on screen to help.
    Returns each eligible invoice with what it still has room to evidence, so
    the pick is informed rather than a guess.

    Ordered oldest first as a convenience for reading — NOT as a default
    selection. Nothing here allocates or attributes anything.
    """
    supplier = Supplier.query.get(supplier_id)
    if supplier is None:
        return jsonify({
            'success': False,
            'message': f'المورد #{supplier_id} غير موجود',
            'error': 'not_found',
        }), 404

    rows = (
        InvoiceGoldObligation.query
        .join(Invoice, Invoice.id == InvoiceGoldObligation.invoice_id)
        .filter(Invoice.supplier_id == supplier_id)
        .order_by(Invoice.date.asc(), Invoice.id.asc())
        .all()
    )

    by_invoice = {}
    for obligation in rows:
        entry = by_invoice.setdefault(obligation.invoice_id, {
            'invoice_id': obligation.invoice_id,
            'date': obligation.invoice.date.isoformat() if obligation.invoice.date else None,
            'karats': [],
            'open_main_karat': 0.0,
        })
        remaining = obligation_attributed_remaining(obligation)
        entry['karats'].append({
            'karat': obligation.karat,
            'gross_weight': obligation.weight,
            'attributed_remaining_main_karat': remaining,
        })
        entry['open_main_karat'] = round(entry['open_main_karat'] + remaining, 2)

    invoices = [e for e in by_invoice.values() if e['open_main_karat'] > WEIGHT_EPSILON]
    return jsonify({'success': True, 'invoices': invoices}), 200


@gold_advances_bp.route('/gold-advances/<int:advance_id>/allocate', methods=['POST'])
@require_auth
@require_permission('gold_advances.allocate')
def allocate_gold_advance(advance_id):
    """Explicitly attribute this much of this Advance to a specific invoice
    gold obligation. Body: {"obligation_id": int, "weight_main_karat": float}.

    This is the ONLY way a GoldAllocation is ever created — Phase 16C removed
    the automatic (FIFO) path entirely, because attribution nobody declared is
    attribution invented.
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
        allocation = _service.allocate(
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
        'message': 'تم تخصيص الذهب للفاتورة',
        'allocation': allocation.to_dict(),
    }), 201
