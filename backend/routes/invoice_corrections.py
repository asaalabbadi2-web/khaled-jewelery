"""«تصحيح فاتورة»: a posted line's karat, weight or price put right (ت-1, the owner 22 Oct 2026).

POST /api/invoices/<id>/corrections/preview -- the entry the correction would
     post, from the server, nothing kept (as the melting's preview, ADR-050);
POST /api/invoices/<id>/corrections         -- the correction, posted;
GET  /api/invoices/<id>/corrections         -- what was corrected, why, who.
The rules are services/invoice_corrections.py's.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from models import Account, Invoice, InvoiceCorrection, JournalEntryLine, db
from services.invoice_corrections import CorrectionRefused, correct_line

invoice_corrections_bp = Blueprint('invoice_corrections', __name__)


def _body():
    data = request.get_json(silent=True) or {}
    return dict(line_id=data.get('line_id'), lines=data.get('lines'), safe_box_id=data.get('safe_box_id'),
                reason=data.get('reason'))


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


def _refused(refused: CorrectionRefused):
    db.session.rollback()
    return jsonify({'error': refused.code, 'message': refused.message, **refused.extra}), 400


def _entry_lines(entry_id):
    """The entry's lines as the melting's preview shows them (ت2): one row a
    side and amount -- its account, debit or credit, cash or gold, its karat."""
    rows = (db.session.query(JournalEntryLine, Account).join(Account, Account.id == JournalEntryLine.account_id)
            .filter(JournalEntryLine.journal_entry_id == entry_id, JournalEntryLine.is_deleted.is_(False))
            .order_by(JournalEntryLine.id).all())
    out = []
    for line, account in rows:
        base = {'account_id': account.id, 'account_number': account.account_number, 'account_name': account.name,
                'description': line.description}
        for side in ('debit', 'credit'):
            cash = float(getattr(line, f'cash_{side}') or 0)
            if cash:
                out.append({**base, 'side': side, 'amount_type': 'cash', 'amount': round(cash, 2), 'karat': None})
            for k in (18, 21, 22, 24):
                grams = float(getattr(line, f'{side}_{k}k') or 0)
                if grams:
                    out.append({**base, 'side': side, 'amount_type': 'gold', 'amount': round(grams, 3), 'karat': k})
    return out


@invoice_corrections_bp.route('/invoices/<int:invoice_id>/corrections/preview', methods=['POST'])
@require_permission('invoices.correct')
def preview_invoice_correction(invoice_id: int):
    try:
        correction = correct_line(db.session.get(Invoice, invoice_id), **_body(), by=_by(), now=datetime.now())
        answer = {'preview': True, 'lines': _entry_lines(correction.journal_entry_id),
                  'before': correction.before, 'after': correction.after, 'cash_delta': correction.cash_delta}
    except CorrectionRefused as refused:
        return _refused(refused)
    finally:
        db.session.rollback()
        db.session.info.pop('_voucher_number_seq_cache', None)
    return jsonify(answer), 200


@invoice_corrections_bp.route('/invoices/<int:invoice_id>/corrections', methods=['POST'])
@require_permission('invoices.correct')
def create_invoice_correction(invoice_id: int):
    try:
        correction = correct_line(db.session.get(Invoice, invoice_id), **_body(), by=_by(), now=datetime.now())
    except CorrectionRefused as refused:
        return _refused(refused)
    db.session.commit()
    return jsonify({**correction.to_dict(), 'lines': _entry_lines(correction.journal_entry_id)}), 201


@invoice_corrections_bp.route('/invoices/<int:invoice_id>/corrections', methods=['GET'])
@require_permission('invoices.view')
def list_invoice_corrections(invoice_id: int):
    """The invoice's corrections, and the safe a correction would start from:
    the one its purchase put its gold in (the screen suggests it; the gold may
    have moved since)."""
    from services.return_lines import purchase_gold_safe_id
    rows = InvoiceCorrection.query.filter_by(invoice_id=invoice_id).order_by(InvoiceCorrection.id).all()
    return jsonify({'corrections': [r.to_dict() for r in rows],
                    'suggested_safe_box_id': purchase_gold_safe_id(invoice_id)}), 200
