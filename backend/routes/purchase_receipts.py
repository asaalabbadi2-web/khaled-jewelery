"""Receiving before the invoice (ADR-087 R2): the routes.

POST /api/purchase-receipts               -- a receipt: the supplier, his paper's
     number, the save attempt's key, its lines by category (the weight
     received, his weight), the approval of a difference above the tolerance.
     Its gold posted (add_invoice, its gold part); refused before the day the
     settings name (Settings.receiving_from).
GET  /api/purchase-receipts?pending=1     -- «استلامات بلا فاتورة»: received,
     their invoice not completed.
POST /api/purchase-receipts/<id>/complete -- the purchase screen's own request
     completing it: its cash posted on the same document (add_invoice, its
     cash part, complete_invoice_id).
The laws are add_invoice's and services/receiving.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, current_app, jsonify, request

from auth_decorators import require_permission
from models import Category, Invoice, InvoiceItem, Supplier, db

purchase_receipts_bp = Blueprint('purchase_receipts', __name__)


def _through_add_invoice(payload: dict, **kw):
    """add_invoice on *payload*, as the edit and the barter call it: in this
    app, signed in as the caller; its answer and status."""
    from routes.invoices import add_invoice
    headers = {'Authorization': request.headers.get('Authorization', '')}
    with current_app.test_request_context('/api/invoices', method='POST', json=payload, headers=headers):
        from flask import g
        g.pop('current_user', None)
        rv = add_invoice(defer_commit=True, **kw)
    resp, status = (rv[0], rv[1]) if isinstance(rv, tuple) else (rv, 201)
    body = resp.get_json(silent=True) or {}
    # one shape: the document under 'invoice' -- add_invoice answers a new one bare
    if int(status) in (200, 201) and 'invoice' not in body and 'id' in body:
        body = {'invoice': body}
    return body, int(status)


def _purchase_of(data: dict) -> dict:
    """A receipt's request as add_invoice reads a purchase: lines by category,
    no cash -- its wage, VAT and payment are the invoice's (ADR-087 §2)."""
    lines = data.get('lines') if isinstance(data.get('lines'), list) else []
    items = []
    for line in lines:
        if not isinstance(line, dict):
            continue
        category = db.session.get(Category, int(line['category_id'])) if line.get('category_id') else None
        items.append({'name': line.get('name') or (category.name if category else ''),
                      'karat': line.get('karat'), 'weight': line.get('weight'), 'quantity': 1,
                      'supplier_weight': line.get('supplier_weight'), 'category_id': line.get('category_id')})
    return {'invoice_type': 'شراء', 'gold_type': 'new', 'supplier_id': data.get('supplier_id'),
            'date': data.get('date') or datetime.now().isoformat(), 'settlement_method': 'credit',
            'amount_paid': 0.0, 'vat_applied': False, 'total': 0.0, 'items': items,
            'request_key': data.get('request_key'), 'supplier_invoice_number': data.get('supplier_invoice_number'),
            'difference_approval': data.get('difference_approval')}


@purchase_receipts_bp.route('/purchase-receipts', methods=['POST'])
@require_permission('invoices.supplier')
def receive():
    from services.receiving import receiving_from, receiving_on
    data = request.get_json(silent=True) or {}
    day = datetime.fromisoformat(data['date']) if data.get('date') else datetime.now()
    if not receiving_on(day):
        start = receiving_from()
        return jsonify({'error': 'receiving_not_active',
                        'message': (f'الاستلام يعمل من {start.isoformat()}' if start
                                    else 'الاستلام لم يُفعَّل بعد: يعمل من أول يوم في 2027')}), 400
    body, status = _through_add_invoice(_purchase_of(data), posting_part='gold')
    if status in (200, 201):
        db.session.commit()
    else:
        db.session.rollback()
    return jsonify(body), status


@purchase_receipts_bp.route('/purchase-receipts', methods=['GET'])
@require_permission('invoices.supplier')
def pending_receipts():
    """«استلامات بلا فاتورة» (ADR-087 §8): received, not yet invoiced."""
    rows = []
    receipts = (Invoice.query.filter(Invoice.invoice_type == 'شراء', Invoice.receiving_stage == 'received')
                .order_by(Invoice.date.desc(), Invoice.id.desc()).all())
    for invoice in receipts:
        supplier = db.session.get(Supplier, invoice.supplier_id) if invoice.supplier_id else None
        by_karat = {}
        for item in InvoiceItem.query.filter_by(invoice_id=invoice.id):
            key = f'{float(item.karat or 0):g}'
            by_karat[key] = round(by_karat.get(key, 0.0) + float(item.weight or 0), 3)
        rows.append({'id': invoice.id, 'invoice_number': invoice.invoice_number, 'date': invoice.date.isoformat(),
                     'supplier_id': invoice.supplier_id, 'supplier_name': getattr(supplier, 'name', None),
                     'supplier_invoice_number': invoice.supplier_invoice_number, 'weight_by_karat': by_karat})
    return jsonify({'receipts': rows}), 200


@purchase_receipts_bp.route('/purchase-receipts/<int:invoice_id>/complete', methods=['POST'])
@require_permission('invoices.supplier')
def complete(invoice_id: int):
    body, status = _through_add_invoice(request.get_json(silent=True) or {}, posting_part='cash',
                                        complete_invoice_id=invoice_id)
    if status in (200, 201):
        db.session.commit()
    else:
        db.session.rollback()
    return jsonify(body), status
