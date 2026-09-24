"""Vouchers domain routes — vouchers_bp registered under /api in app.py."""
from __future__ import annotations

import json
from datetime import datetime, date, timedelta

from flask import Blueprint, g, jsonify, request
from sqlalchemy import String, cast, case, func, or_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    AuditLog,
    Customer,
    Employee,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    PaymentMethod,
    SafeBox,
    SafeBoxTransaction,
    Supplier,
    SupplierGoldAdvance,
    Voucher,
    VoucherAccountLine,
)

from core.number_helpers import _coerce_float
from auth_decorators import require_permission

from pricing.karat_service import get_main_karat
from accounting.voucher_engine import (
    generate_voucher_number,
    create_journal_entry_from_voucher,
    _append_safe_transactions_for_voucher,
    _generate_journal_entry_number,
    _update_account_balances_from_journal_lines,
)
from allocation_service import AllocationService
from services.invoice_payment_state_service import (
    InvoicePaymentStateService,
    sync_invoice_payment_state_after_voucher_approval,
)
from services.gold_allocation_service import (
    GoldAllocationService,
    sync_gold_advance_after_voucher_approval,
    sync_gold_attribution_after_voucher_approval,
    remove_attributions_for_voucher,
)
from accounting.wages import _ensure_gold24k_commission_revenue_account
from routes import (
    _resolve_account_id_for_amount_type,
)

vouchers_bp = Blueprint('vouchers', __name__)

def _append_safe_reversal_transactions_for_voucher(voucher: Voucher, created_by=None, reason=None):
    """Append reversing SafeBoxTransaction rows for a previously-approved voucher."""
    if not voucher or not getattr(voucher, 'id', None):
        return []

    # Avoid double reversal
    existing_reversal = (
        SafeBoxTransaction.query.filter_by(ref_type='voucher_reversal', ref_id=voucher.id)
        .order_by(SafeBoxTransaction.id.desc())
        .first()
    )
    if existing_reversal:
        return []

    original = SafeBoxTransaction.query.filter(
        SafeBoxTransaction.ref_id == voucher.id,
        SafeBoxTransaction.ref_type.in_(['voucher', 'invoice_payment']),
    ).all()
    if not original:
        return []

    created = []
    for tx in original:
        rev = SafeBoxTransaction(
            safe_box_id=tx.safe_box_id,
            ref_type='voucher_reversal',
            ref_id=voucher.id,
            payment_method_id=tx.payment_method_id,
            direction='out' if (tx.direction or 'in') == 'in' else 'in',
            amount_cash=float(tx.amount_cash or 0.0),
            weight_18k=float(tx.weight_18k or 0.0),
            weight_21k=float(tx.weight_21k or 0.0),
            weight_22k=float(tx.weight_22k or 0.0),
            weight_24k=float(tx.weight_24k or 0.0),
            notes=(reason or '') or f"Reversal for voucher {voucher.voucher_number}",
            created_by=created_by or voucher.cancelled_by if hasattr(voucher, 'cancelled_by') else created_by or voucher.created_by,
        )
        db.session.add(rev)
        created.append(rev)
    return created

@vouchers_bp.route('/vouchers', methods=['GET'])
def get_vouchers():
    """
    Get list of vouchers with optional filtering and pagination
    Query parameters:
    - page: int (for pagination)
    - per_page: int (for pagination)
    - type: receipt, payment, adjustment
    - party_type: customer, supplier, other
    - status: active, cancelled
    - date_from: YYYY-MM-DD
    - date_to: YYYY-MM-DD
    - customer_id: int
    - supplier_id: int
    - search: string (searches voucher_number and description)
    - reference_type: string (invoice, voucher, journal_entry, manual)
    - reference_id: int
    """
    def _empty_summary():
        return {
            'total_vouchers': 0,
            'receipt_count': 0,
            'payment_count': 0,
            'adjustment_count': 0,
            'pending_count': 0,
            'approved_count': 0,
            'cancelled_count': 0,
            'rejected_count': 0,
            'total_cash': 0.0,
            'total_gold': 0.0,
            'total_gold_main_karat': 0.0,
        }

    def _normalize_text(value):
        return (value or '').strip()

    def _resolve_party_name(voucher):
        if voucher.customer and voucher.customer.name:
            return voucher.customer.name.strip()
        if voucher.supplier and voucher.supplier.name:
            return voucher.supplier.name.strip()
        if voucher.employee and voucher.employee.name:
            return voucher.employee.name.strip()
        if voucher.party_name:
            return voucher.party_name.strip()
        return ''

    page = max(request.args.get('page', 1, type=int) or 1, 1)
    per_page = request.args.get('per_page', 20, type=int) or 20
    per_page = max(1, min(per_page, 100))

    sort_by = _normalize_text(request.args.get('sort_by')).lower() or 'date'
    sort_order = _normalize_text(request.args.get('sort_order')).lower() or 'desc'
    search_type = _normalize_text(request.args.get('search_type')).lower() or 'all'
    creator = _normalize_text(request.args.get('creator'))
    party = _normalize_text(request.args.get('party'))

    query = Voucher.query.options(
        joinedload(Voucher.customer),
        joinedload(Voucher.supplier),
        joinedload(Voucher.employee),
        joinedload(Voucher.journal_entry),
    )

    joined_party_tables = False

    def _ensure_party_joins(base_query):
        nonlocal joined_party_tables
        if joined_party_tables:
            return base_query
        joined_party_tables = True
        return (
            base_query
            .outerjoin(Customer, Voucher.customer_id == Customer.id)
            .outerjoin(Supplier, Voucher.supplier_id == Supplier.id)
            .outerjoin(Employee, Voucher.employee_id == Employee.id)
        )

    voucher_type = _normalize_text(request.args.get('type')).lower()
    if voucher_type and voucher_type != 'all':
        query = query.filter(Voucher.voucher_type == voucher_type)

    party_type = _normalize_text(request.args.get('party_type')).lower()
    if party_type and party_type != 'all':
        query = query.filter(Voucher.party_type == party_type)

    status = _normalize_text(request.args.get('status')).lower()
    if status and status != 'all':
        if status == 'active':
            query = query.filter(Voucher.status.in_(['pending', 'approved']))
        else:
            query = query.filter(Voucher.status == status)

    date_from = request.args.get('date_from')
    if date_from:
        try:
            date_from_obj = datetime.fromisoformat(date_from)
            query = query.filter(Voucher.date >= date_from_obj)
        except Exception:
            pass

    date_to = request.args.get('date_to')
    if date_to:
        try:
            date_to_obj = datetime.fromisoformat(date_to)
            if date_to_obj.hour == 0 and date_to_obj.minute == 0 and date_to_obj.second == 0 and date_to_obj.microsecond == 0:
                date_to_obj = date_to_obj.replace(hour=23, minute=59, second=59, microsecond=999999)
            query = query.filter(Voucher.date <= date_to_obj)
        except Exception:
            pass

    customer_id = request.args.get('customer_id')
    if customer_id:
        query = query.filter(Voucher.customer_id == int(customer_id))

    supplier_id = request.args.get('supplier_id')
    if supplier_id:
        query = query.filter(Voucher.supplier_id == int(supplier_id))

    reference_type = _normalize_text(request.args.get('reference_type')).lower()
    if reference_type and reference_type != 'all':
        query = query.filter(Voucher.reference_type == reference_type)

    reference_id = request.args.get('reference_id')
    if reference_id not in (None, '', False):
        try:
            query = query.filter(Voucher.reference_id == int(reference_id))
        except Exception:
            pass

    if creator:
        query = query.filter(func.lower(func.coalesce(Voucher.created_by, '')) == creator.lower())

    if party:
        query = _ensure_party_joins(query)
        party_term = f'%{party}%'
        query = query.filter(
            or_(
                Customer.name.ilike(party_term),
                Supplier.name.ilike(party_term),
                Employee.name.ilike(party_term),
                Voucher.party_name.ilike(party_term),
            )
        )

    search = _normalize_text(request.args.get('search'))
    if search:
        search_term = f'%{search}%'
        numeric_search = None
        try:
            numeric_search = float(search)
        except Exception:
            numeric_search = None

        if search_type == 'number':
            query = query.filter(Voucher.voucher_number.ilike(search_term))
        elif search_type == 'party':
            query = _ensure_party_joins(query)
            query = query.filter(
                or_(
                    Customer.name.ilike(search_term),
                    Supplier.name.ilike(search_term),
                    Employee.name.ilike(search_term),
                    Voucher.party_name.ilike(search_term),
                )
            )
        elif search_type == 'description':
            query = query.filter(
                or_(
                    Voucher.description.ilike(search_term),
                    Voucher.notes.ilike(search_term),
                    Voucher.reference_number.ilike(search_term),
                )
            )
        elif search_type == 'reference':
            query = query.filter(
                or_(
                    Voucher.reference_number.ilike(search_term),
                    Voucher.reference_type.ilike(search_term),
                    cast(Voucher.reference_id, String).ilike(search_term),
                )
            )
        elif search_type == 'amount' and numeric_search is not None:
            query = query.filter(
                or_(
                    Voucher.amount_cash == numeric_search,
                    Voucher.amount_gold == numeric_search,
                )
            )
        else:
            query = _ensure_party_joins(query)
            amount_match = []
            if numeric_search is not None:
                amount_match = [
                    Voucher.amount_cash == numeric_search,
                    Voucher.amount_gold == numeric_search,
                ]
            query = query.filter(
                or_(
                    Voucher.voucher_number.ilike(search_term),
                    Voucher.description.ilike(search_term),
                    Voucher.notes.ilike(search_term),
                    Voucher.reference_number.ilike(search_term),
                    Customer.name.ilike(search_term),
                    Supplier.name.ilike(search_term),
                    Employee.name.ilike(search_term),
                    Voucher.party_name.ilike(search_term),
                    *amount_match,
                )
            )

    # ── Summary via SQL aggregates (no full .all()) ──────────────────────
    # Clone the query to a scalar aggregate before adding ORDER BY / pagination.
    summary_q = query.order_by(None).with_entities(
        func.count(Voucher.id),
        func.sum(case((Voucher.voucher_type == 'receipt', 1), else_=0)),
        func.sum(case((Voucher.voucher_type == 'payment', 1), else_=0)),
        func.sum(case((Voucher.voucher_type == 'adjustment', 1), else_=0)),
        func.sum(case((func.lower(func.coalesce(Voucher.status, '')) == 'pending', 1), else_=0)),
        func.sum(case((func.lower(func.coalesce(Voucher.status, '')) == 'approved', 1), else_=0)),
        func.sum(case((func.lower(func.coalesce(Voucher.status, '')) == 'cancelled', 1), else_=0)),
        func.sum(case((func.lower(func.coalesce(Voucher.status, '')) == 'rejected', 1), else_=0)),
        func.sum(func.coalesce(Voucher.amount_cash, 0.0)),
        func.sum(func.coalesce(Voucher.amount_gold, 0.0)),
    )
    sr = summary_q.one()
    current_summary = {
        'total_vouchers': int(sr[0] or 0),
        'receipt_count': int(sr[1] or 0),
        'payment_count': int(sr[2] or 0),
        'adjustment_count': int(sr[3] or 0),
        'pending_count': int(sr[4] or 0),
        'approved_count': int(sr[5] or 0),
        'cancelled_count': int(sr[6] or 0),
        'rejected_count': int(sr[7] or 0),
        'total_cash': round(float(sr[8] or 0.0), 2),
        'total_gold': round(float(sr[9] or 0.0), 6),
        'total_gold_main_karat': 0.0,  # gold_main_karat requires per-karat conversion; omit in fast path
    }

    # ── Distinct creators (one lightweight query) ────────────────────────
    creator_rows = (
        query.order_by(None)
        .with_entities(Voucher.created_by)
        .distinct()
        .all()
    )
    creator_names = sorted({(r[0] or '').strip() for r in creator_rows if (r[0] or '').strip()})
    available_creators = [{'name': n} for n in creator_names]

    # ── Distinct party names (COALESCE over joined tables) ───────────────
    party_q = _ensure_party_joins(query.order_by(None))
    party_rows = (
        party_q
        .with_entities(
            func.coalesce(
                func.nullif(Customer.name, ''),
                func.nullif(Supplier.name, ''),
                func.nullif(Employee.name, ''),
                func.nullif(Voucher.party_name, ''),
            )
        )
        .distinct()
        .all()
    )
    party_names = sorted({(r[0] or '').strip() for r in party_rows if (r[0] or '').strip()})
    available_parties = [{'name': n} for n in party_names]

    created_sort_expr = func.coalesce(Voucher.created_at, Voucher.date)

    if sort_by == 'number':
        sort_expr = Voucher.voucher_number
    elif sort_by == 'party':
        query = _ensure_party_joins(query)
        sort_expr = func.coalesce(Customer.name, Supplier.name, Employee.name, Voucher.party_name, '')
    elif sort_by == 'type':
        sort_expr = Voucher.voucher_type
    elif sort_by == 'cash':
        sort_expr = Voucher.amount_cash
    elif sort_by == 'gold':
        sort_expr = Voucher.amount_gold
    elif sort_by == 'status':
        sort_expr = Voucher.status
    elif sort_by == 'creator':
        sort_expr = func.coalesce(Voucher.created_by, '')
    elif sort_by == 'reference':
        sort_expr = func.coalesce(Voucher.reference_number, '')
    else:
        sort_expr = created_sort_expr

    if sort_order == 'asc':
        query = query.order_by(sort_expr.asc(), created_sort_expr.asc(), Voucher.id.asc())
    else:
        query = query.order_by(sort_expr.desc(), created_sort_expr.desc(), Voucher.id.desc())

    paginated_vouchers = query.paginate(page=page, per_page=per_page, error_out=False)

    result = {
        'vouchers': [v.to_dict() for v in paginated_vouchers.items],
        'total': paginated_vouchers.total,
        'pages': paginated_vouchers.pages,
        'current_page': paginated_vouchers.page,
        'per_page': paginated_vouchers.per_page,
        'current_summary': current_summary,
        'available_creators': available_creators,
        'available_parties': available_parties,
    }

    return jsonify(result)

@vouchers_bp.route('/vouchers/<int:voucher_id>', methods=['GET'])
def get_voucher(voucher_id):
    """Get single voucher by ID"""
    voucher = Voucher.query.get_or_404(voucher_id)
    return jsonify(voucher.to_dict())

def _validate_and_summarize_voucher_account_lines(account_lines_data):
    if not account_lines_data:
        return None, jsonify({'error': 'account_lines is required and cannot be empty'}), 400

    main_karat = _coerce_float(get_main_karat(), 21.0)
    if main_karat <= 0:
        main_karat = 21.0

    total_debit_cash = 0.0
    total_credit_cash = 0.0
    total_debit_gold_raw = 0.0
    total_credit_gold_raw = 0.0
    total_debit_gold_main = 0.0
    total_credit_gold_main = 0.0

    allowed_line_keys = {
        'account_id',
        'line_type',
        'amount_type',
        'amount',
        'karat',
        'description',
        'gross_weight',
        'net_weight',
        'stones_weight',
    }
    normalized_lines = []

    for line in account_lines_data:
        if not isinstance(line, dict):
            return None, jsonify({'error': 'Each account line must be an object'}), 400

        unknown_keys = sorted(set(line.keys()) - allowed_line_keys)
        if unknown_keys:
            return None, jsonify({
                'error': 'unknown_voucher_account_line_keys',
                'unknown_keys': unknown_keys,
            }), 400

        if 'account_id' not in line or 'line_type' not in line or 'amount_type' not in line or 'amount' not in line:
            return None, jsonify({'error': 'Each account line must have account_id, line_type, amount_type, and amount'}), 400

        line_type = str(line.get('line_type') or '').strip().lower()
        amount_type = str(line.get('amount_type') or '').strip().lower()
        if line_type not in ['debit', 'credit']:
            return None, jsonify({'error': 'line_type must be either debit or credit'}), 400
        if amount_type not in ['cash', 'gold']:
            return None, jsonify({'error': 'amount_type must be either cash or gold'}), 400

        amount = _coerce_float(line.get('amount'), None)
        if amount is None or amount <= 0:
            return None, jsonify({'error': 'Amount must be greater than zero'}), 400

        if amount_type == 'cash':
            if line_type == 'debit':
                total_debit_cash += amount
            else:
                total_credit_cash += amount
            normalized_lines.append({
                'account_id': line['account_id'],
                'line_type': line_type,
                'amount_type': amount_type,
                'amount': amount,
                'karat': None,
                'gross_weight': None,
                'net_weight': None,
                'stones_weight': 0.0,
                'description': line.get('description'),
            })
            continue

        karat = _coerce_float(line.get('karat'), None)
        if karat is None or karat <= 0:
            return None, jsonify({'error': 'karat is required when amount_type is gold'}), 400

        net_weight = _coerce_float(line.get('net_weight'), amount)
        if net_weight is None or net_weight <= 0:
            return None, jsonify({'error': 'net_weight must be greater than zero for gold lines'}), 400
        if abs(net_weight - amount) > 0.001:
            return None, jsonify({'error': 'amount must match net_weight for gold lines'}), 400

        stones_weight = _coerce_float(line.get('stones_weight'), 0.0)
        if stones_weight < 0:
            return None, jsonify({'error': 'stones_weight cannot be negative'}), 400

        gross_weight = _coerce_float(line.get('gross_weight'), net_weight + stones_weight)
        if gross_weight is None or gross_weight <= 0:
            return None, jsonify({'error': 'gross_weight must be greater than zero for gold lines'}), 400
        if gross_weight + 0.001 < net_weight:
            return None, jsonify({'error': 'gross_weight cannot be less than net_weight'}), 400

        amount_main = (amount * karat) / main_karat
        if line_type == 'debit':
            total_debit_gold_raw += amount
            total_debit_gold_main += amount_main
        else:
            total_credit_gold_raw += amount
            total_credit_gold_main += amount_main

        normalized_lines.append({
            'account_id': line['account_id'],
            'line_type': line_type,
            'amount_type': amount_type,
            'amount': amount,
            'karat': karat,
            'gross_weight': round(gross_weight, 6),
            'net_weight': round(net_weight, 6),
            'stones_weight': round(stones_weight, 6),
            'description': line.get('description'),
        })

    if abs(total_debit_cash - total_credit_cash) > 0.01:
        return None, jsonify({'error': f'Cash amounts not balanced: Debit={total_debit_cash}, Credit={total_credit_cash}'}), 400

    if abs(total_debit_gold_main - total_credit_gold_main) > 0.001:
        return None, jsonify({
            'error': (
                'Gold amounts not balanced in main karat: '
                f'Debit={round(total_debit_gold_main, 6)}, '
                f'Credit={round(total_credit_gold_main, 6)}'
            ),
            'main_karat': int(round(main_karat)),
        }), 400

    return {
        'amount_cash': round(total_debit_cash, 6),
        'amount_gold': round(total_debit_gold_raw or total_credit_gold_raw, 6),
        'gross_weight': round(sum(float(line['gross_weight'] or 0.0) for line in normalized_lines if line['amount_type'] == 'gold'), 6),
        'net_weight': round(sum(float(line['net_weight'] or 0.0) for line in normalized_lines if line['amount_type'] == 'gold'), 6),
        'stones_weight': round(sum(float(line['stones_weight'] or 0.0) for line in normalized_lines if line['amount_type'] == 'gold'), 6),
        'account_lines': normalized_lines,
    }, None, None

def _upsert_voucher_from_payload(voucher, data, *, is_create=False):
    if not isinstance(data, dict):
        return jsonify({'error': 'Invalid request body'}), 400

    allowed_keys = {
        'id',
        'voucher_type',
        'date',
        'party_type',
        'customer_id',
        'supplier_id',
        'employee_id',
        'party_name',
        'description',
        'reference_type',
        'reference_id',
        'reference_number',
        'attachments',
        'notes',
        'receiver_name',
        'created_by',
        'account_lines',
        'gold24k_settlement',
        'gold24k_weight',
        'gold24k_commission_per_gram',
        'gold24k_commission_total',
        'karat_diff_settlement',
        'karat_diff_owed_karat',
        'karat_diff_paid_karat',
        'karat_diff_weight',
        'karat_diff_per_gram',
        'karat_diff_total',
        'karat_diff_earn_total',
        'karat_diff_pay_total',
    }
    unknown_keys = sorted(set(data.keys()) - allowed_keys)
    if unknown_keys:
        return jsonify({
            'error': 'unknown_voucher_keys',
            'unknown_keys': unknown_keys,
        }), 400

    voucher_type = str(data.get('voucher_type') or voucher.voucher_type or '').strip().lower()
    if voucher_type not in ['receipt', 'payment', 'adjustment']:
        return jsonify({'error': 'Invalid voucher_type'}), 400

    account_lines_data = data.get('account_lines')
    if account_lines_data is None:
        account_lines_data = [
            {
                'account_id': line.account_id,
                'line_type': line.line_type,
                'amount_type': line.amount_type,
                'amount': float(line.amount or 0.0),
                'karat': line.karat,
                'gross_weight': line.gross_weight,
                'net_weight': line.net_weight,
                'stones_weight': line.stones_weight,
                'description': line.description,
            }
            for line in voucher.account_lines.all()
        ]

    summary, error_response, status_code = _validate_and_summarize_voucher_account_lines(account_lines_data)
    if error_response is not None:
        return error_response, status_code

    for line in account_lines_data:
        account = Account.query.get(line['account_id'])
        if not account:
            return jsonify({'error': f'Account {line["account_id"]} not found'}), 404

    voucher_date_raw = data.get('date')
    if voucher_date_raw:
        voucher.date = datetime.fromisoformat(voucher_date_raw)
    elif is_create and not voucher.date:
        voucher.date = datetime.now()

    voucher.voucher_type = voucher_type
    voucher.party_type = data.get('party_type')
    voucher.customer_id = data.get('customer_id') if voucher.party_type == 'customer' else None
    voucher.supplier_id = data.get('supplier_id') if voucher.party_type == 'supplier' else None
    voucher.employee_id = data.get('employee_id') if voucher.party_type == 'employee' else None
    if voucher.party_type == 'employee' and voucher.employee_id:
        employee = Employee.query.get(voucher.employee_id)
        voucher.party_name = data.get('party_name') or (employee.name if employee else None)
    else:
        voucher.party_name = data.get('party_name') if voucher.party_type not in ('customer', 'supplier') else None

    # Fallback: when party_type == 'other' and party_name still not set,
    # look up the account name from the party-side line in account_lines.
    if voucher.party_type == 'other' and not voucher.party_name:
        _party_lt = 'credit' if voucher_type == 'receipt' else 'debit'
        for _ld in (summary.get('account_lines') or []):
            if _ld.get('line_type') == _party_lt:
                try:
                    _acc = Account.query.get(_ld.get('account_id'))
                    if _acc and _acc.name:
                        voucher.party_name = _acc.name.strip()
                        break
                except Exception:
                    pass
    voucher.amount_cash = summary['amount_cash']
    voucher.amount_gold = summary['amount_gold']
    voucher.gold_karat = None
    voucher.description = data.get('description')
    voucher.reference_type = data.get('reference_type', voucher.reference_type)
    voucher.reference_id = data.get('reference_id', voucher.reference_id)
    voucher.reference_number = data.get('reference_number', voucher.reference_number)
    voucher.attachments = data.get('attachments', voucher.attachments)
    voucher.notes = data.get('notes')
    voucher.receiver_name = data.get('receiver_name')

    for existing_line in voucher.account_lines.all():
        db.session.delete(existing_line)

    # Resolve gold-type lines to their memo/weight account immediately, not
    # just at posting time (create_journal_entry_from_voucher applies the
    # same resolution again, which is then a no-op). Otherwise the voucher's
    # own stored lines show a misleading pending state -- e.g. a financial
    # account appearing to carry a gold amount that approval will silently
    # redirect away from it.
    _line_safe_account_ids = set()
    _line_account_cache = {}
    try:
        _line_account_ids = list({
            int(ld['account_id']) for ld in summary['account_lines']
            if ld.get('account_id') is not None
        })
        if _line_account_ids:
            for sb in SafeBox.query.filter(SafeBox.account_id.in_(_line_account_ids)).all():
                if getattr(sb, 'account_id', None) is not None:
                    _line_safe_account_ids.add(int(sb.account_id))
            for _a in Account.query.filter(Account.id.in_(_line_account_ids)).all():
                _line_account_cache[int(_a.id)] = _a
    except Exception:
        _line_safe_account_ids = set()

    for line_data in summary['account_lines']:
        resolved_account_id = _resolve_account_id_for_amount_type(
            line_data['account_id'],
            str(line_data['amount_type'] or ''),
            safe_account_ids=_line_safe_account_ids,
            account_cache=_line_account_cache,
        )
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=resolved_account_id,
            line_type=str(line_data['line_type']).strip().lower(),
            amount_type=str(line_data['amount_type']).strip().lower(),
            amount=float(line_data['amount']),
            karat=_coerce_float(line_data.get('karat'), None),
            gross_weight=_coerce_float(line_data.get('gross_weight'), None),
            net_weight=_coerce_float(line_data.get('net_weight'), None),
            stones_weight=_coerce_float(line_data.get('stones_weight'), 0.0),
            description=line_data.get('description'),
        ))

    # عمولة السداد بذهب صافي — قيد العمولة فقط (حركة الوزن مدعومة من سطور السند)
    if data.get('gold24k_settlement') and voucher.voucher_type == 'payment' and voucher.supplier_id:
        try:
            g24_weight = float(data.get('gold24k_weight') or 0)
            g24_commission_per_gram = float(data.get('gold24k_commission_per_gram') or 0)
            g24_commission_total = float(data.get('gold24k_commission_total') or 0)

            if g24_commission_total > 0:
                supplier = Supplier.query.get(voucher.supplier_id)
                if supplier:
                    supplier_cash_account_id = supplier.account_id
                    revenue_account_id = _ensure_gold24k_commission_revenue_account()

                    if supplier_cash_account_id and revenue_account_id:
                        je_commission = JournalEntry(
                            entry_number=_generate_journal_entry_number(entry_date=voucher.date),
                            date=voucher.date,
                            description=f'عمولة السداد بذهب صافي — سند #{voucher.voucher_number} ({g24_weight:.3f} جم × {g24_commission_per_gram:.2f} ر.س)',
                            reference_type='voucher',
                            reference_id=voucher.id,
                            is_posted=False,
                            created_by=data.get('created_by', 'system'),
                        )
                        db.session.add(je_commission)
                        db.session.flush()
                        db.session.add(JournalEntryLine(
                            journal_entry_id=je_commission.id,
                            account_id=supplier_cash_account_id,
                            cash_debit=g24_commission_total, cash_credit=0,
                        ))
                        db.session.add(JournalEntryLine(
                            journal_entry_id=je_commission.id,
                            account_id=revenue_account_id,
                            cash_debit=0, cash_credit=g24_commission_total,
                        ))
        except Exception as _g24_err:
            print(f"[_upsert_voucher] خطأ في قيود السداد بذهب صافي: {_g24_err}")

    # عمولة / رسوم فرق العيار — تخزين فقط، القيود تُنشأ عند الاعتماد
    voucher.karat_diff_earn_total = float(data.get('karat_diff_earn_total') or 0)
    voucher.karat_diff_pay_total = float(data.get('karat_diff_pay_total') or 0)

    return None

@vouchers_bp.route('/vouchers', methods=['POST'])
def create_voucher():
    """
    Create a new voucher with automatic journal entry - النسخة المحدّثة
    
    يدعم سطور حسابات متعددة (نقد + عدة عيارات ذهب)
    
    Required fields:
    - voucher_type: receipt, payment, adjustment
    - date: ISO format
    - account_lines: [
        {
          "account_id": int,
          "line_type": "debit" or "credit",
          "amount_type": "cash" or "gold",
          "amount": float,
          "karat": float (optional, required if amount_type='gold'),
          "description": string (optional)
        },
        ...
      ]
    
    Optional fields:
    - party_type: customer, supplier, other
    - customer_id or supplier_id
    - party_name (if not customer/supplier)
    - description
    - reference_type, reference_id, reference_number
    - notes
    """
    data = request.get_json()
    
    # Validation
    if not isinstance(data, dict) or 'voucher_type' not in data:
        return jsonify({'error': 'voucher_type is required'}), 400
    
    if data['voucher_type'] not in ['receipt', 'payment', 'adjustment']:
        return jsonify({'error': 'Invalid voucher_type'}), 400
    
    if 'account_lines' not in data or not data['account_lines']:
        return jsonify({'error': 'account_lines is required and cannot be empty'}), 400
    
    try:
        # Parse date
        voucher_date = datetime.fromisoformat(data.get('date', datetime.now().isoformat()))

        # Generate voucher number (date-aware)
        voucher_number = generate_voucher_number(data['voucher_type'], voucher_date=voucher_date)

        # Create voucher
        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type=data['voucher_type'],
            date=voucher_date,
            party_type=None,
            customer_id=None,
            supplier_id=None,
            party_name=None,
            amount_cash=0.0,
            amount_gold=0.0,
            gold_karat=None,  # لم يعد يستخدم (الآن في سطور الحسابات)
            description=None,
            reference_type=None,
            reference_id=None,
            reference_number=None,
            notes=None,
            created_by=data.get('created_by', 'system'),
            status='pending'
        )
        
        db.session.add(voucher)
        db.session.flush()  # Get the voucher ID

        upsert_error = _upsert_voucher_from_payload(voucher, data, is_create=True)
        if upsert_error is not None:
            db.session.rollback()
            return upsert_error

        # ── Auto-approve when voucher_auto_post is ON ──────────────────────
        try:
            from core.settings import _get_settings_singleton
            _post_settings = _get_settings_singleton(create_if_missing=False)
            _should_auto_post = bool(
                _post_settings and getattr(_post_settings, 'voucher_auto_post', False)
            )
        except Exception:
            _should_auto_post = False

        if _should_auto_post:
            try:
                approved_by = data.get('created_by', 'system')
                journal_entry = create_journal_entry_from_voucher(voucher)
                journal_entry.is_posted = True
                journal_entry.posted_at = datetime.now()
                journal_entry.posted_by = approved_by
                db.session.flush()

                voucher.status = 'approved'
                voucher.approved_at = datetime.now()
                voucher.approved_by = approved_by
                voucher.journal_entry_id = journal_entry.id

                _append_safe_transactions_for_voucher(voucher, created_by=approved_by)

                try:
                    from posting_routes import _create_and_post_karat_diff_entries_for_voucher
                    _create_and_post_karat_diff_entries_for_voucher(voucher, approved_by)
                except Exception:
                    pass

                try:
                    _update_account_balances_from_journal_lines(journal_entry.lines or [])
                except Exception:
                    pass
            except Exception as _ae:
                # auto-approve failed — leave voucher as pending, don't fail creation
                import traceback as _tb
                _tb.print_exc()
                print(f'[create_voucher] auto-approve failed, left as pending: {_ae}')

        db.session.commit()

        return jsonify(voucher.to_dict()), 201

    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Failed to create voucher: {str(e)}'}), 500

@vouchers_bp.route('/vouchers/<int:voucher_id>', methods=['PUT'])
def update_voucher(voucher_id):
    """Update voucher and replace its account lines for editable statuses."""
    voucher = Voucher.query.get_or_404(voucher_id)
    
    if voucher.status in {'approved', 'cancelled', 'voided'}:
        return jsonify({'error': 'Cannot edit this voucher in its current status'}), 400
    
    data = request.get_json()
    
    try:
        upsert_error = _upsert_voucher_from_payload(voucher, data or {}, is_create=False)
        if upsert_error is not None:
            db.session.rollback()
            return upsert_error
        
        db.session.commit()
        
        return jsonify(voucher.to_dict())
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update voucher: {str(e)}'}), 500

@vouchers_bp.route('/vouchers/<int:voucher_id>', methods=['DELETE'])
def delete_voucher(voucher_id):
    """Delete voucher - only if not linked to journal entry"""
    voucher = Voucher.query.get_or_404(voucher_id)
    
    if voucher.journal_entry_id:
        return jsonify({'error': 'Cannot delete voucher linked to journal entry. Cancel it instead.'}), 400
    
    data = request.get_json(silent=True) or {}
    deleted_by = data.get('deleted_by') or request.headers.get('X-User-Name') or 'system'
    reason = data.get('reason') or 'delete'

    try:
        # Audit log (before hard delete)
        try:
            AuditLog.log_action(
                user_name=deleted_by,
                action='delete_voucher',
                entity_type='Voucher',
                entity_id=voucher.id,
                entity_number=voucher.voucher_number,
                details=json.dumps({
                    'voucher_type': voucher.voucher_type,
                    'amount_cash': float(voucher.amount_cash or 0.0),
                    'amount_gold': float(voucher.amount_gold or 0.0),
                    'reason': reason,
                }, ensure_ascii=False),
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=True,
            )
        except Exception:
            pass

        db.session.delete(voucher)
        db.session.commit()
        return jsonify({'message': 'Voucher deleted successfully'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete voucher: {str(e)}'}), 500

@vouchers_bp.route('/vouchers/<int:voucher_id>/approve', methods=['POST'])
def approve_voucher(voucher_id):
    """
    ترحيل السند (Approve/Post Voucher)
    
    يقوم بـ:
    1. تغيير حالة السند إلى 'approved'
    2. إنشاء قيد محاسبي تلقائي من السند
    3. ربط السند بالقيد المحاسبي
    """
    voucher = Voucher.query.get_or_404(voucher_id)
    
    # التحقق من الحالة
    if voucher.status == 'approved':
        return jsonify({'error': 'السند مرحّل بالفعل'}), 400
    
    if voucher.status == 'cancelled':
        return jsonify({'error': 'لا يمكن ترحيل سند ملغى'}), 400
    
    if voucher.journal_entry_id:
        return jsonify({'error': 'السند مرتبط بقيد محاسبي بالفعل'}), 400
    
    data = request.get_json() or {}
    approved_by = data.get('approved_by', 'user')
    
    try:
        # إنشاء القيد المحاسبي
        journal_entry = create_journal_entry_from_voucher(voucher)

        # Mark the JE as posted immediately — voucher approval means finalised.
        journal_entry.is_posted = True
        journal_entry.posted_at = datetime.now()
        journal_entry.posted_by = approved_by
        db.session.flush()

        # تحديث السند
        voucher.status = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = approved_by
        voucher.journal_entry_id = journal_entry.id

        # Ledger: append SafeBoxTransaction rows for any safe-box lines
        _append_safe_transactions_for_voucher(voucher, created_by=approved_by)

        # رحّل كل القيود المرتبطة بالسند (gold24k وغيرها)
        _now = datetime.now()
        for _je in JournalEntry.query.filter_by(
            reference_type='voucher', reference_id=voucher_id, is_posted=False
        ).filter(JournalEntry.is_deleted == False).all():
            _je.is_posted = True
            _je.posted_at = _now
            _je.posted_by = approved_by

        # أنشئ وارحّل قيود عمولة / رسوم فرق العيار
        from posting_routes import _create_and_post_karat_diff_entries_for_voucher
        _create_and_post_karat_diff_entries_for_voucher(voucher, approved_by)

        # Recompute stored Account.balance_* for all accounts in the voucher JE.
        # create_journal_entry_from_voucher marks the JE posted but never
        # triggers the recalculation — do it here so the trial balance stays clean.
        try:
            if journal_entry:
                _update_account_balances_from_journal_lines(journal_entry.lines or [])
        except Exception as _rc_exc:
            print(f"⚠️ recalculate balances after voucher approve skipped: {_rc_exc}")

        # Sync the linked invoice's payment status — see
        # sync_invoice_payment_state_after_voucher_approval's own docstring
        # for exactly which shape this does and does not fix.
        sync_invoice_payment_state_after_voucher_approval(voucher)
        sync_gold_advance_after_voucher_approval(voucher)
        # Same transaction as the approval on purpose: a failure here must
        # fail the approval rather than leave a posted settlement with no
        # attribution. Not wrapped in try/except for that reason.
        sync_gold_attribution_after_voucher_approval(voucher)

        # Audit log
        try:
            AuditLog.log_action(
                user_name=approved_by,
                action='approve_voucher',
                entity_type='Voucher',
                entity_id=voucher.id,
                entity_number=voucher.voucher_number,
                details=json.dumps({
                    'voucher_type': voucher.voucher_type,
                    'amount_cash': float(voucher.amount_cash or 0.0),
                    'amount_gold': float(voucher.amount_gold or 0.0),
                }, ensure_ascii=False),
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=True,
            )
        except Exception:
            pass
        
        db.session.commit()
        
        return jsonify({
            'message': 'تم ترحيل السند بنجاح',
            'voucher': voucher.to_dict(),
            'journal_entry': {
                'id': journal_entry.id,
                'entry_number': journal_entry.entry_number,
                'date': journal_entry.date.isoformat()
            }
        }), 200
        
    except ValueError as e:
        db.session.rollback()
        msg = str(e)
        if msg.startswith('karat_mismatch_for_safe_box:'):
            # Provide a clean client-facing error.
            return jsonify({
                'error': 'karat_mismatch_for_safe_box',
                'message': 'عيار الحركة لا يتطابق مع عيار الخزنة (الخزنة مخصصة لعيار واحد)',
                'details': msg,
            }), 400
        return jsonify({'error': 'validation_error', 'message': msg}), 400
    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'فشل ترحيل السند: {str(e)}'}), 500

def _reverse_voucher_journal_entry(voucher, cancelled_by='system', reason=None):
    """Create a reversing journal entry for a voucher if one exists."""
    if not voucher or not voucher.journal_entry_id:
        return None

    existing = (
        JournalEntry.query.filter_by(reference_type='voucher_reversal', reference_id=voucher.id)
        .order_by(JournalEntry.id.desc())
        .first()
    )
    if existing:
        return existing

    original_entry = JournalEntry.query.get(voucher.journal_entry_id)
    if not original_entry:
        return None

    description_parts = [f'عكس سند #{voucher.voucher_number}']
    if reason:
        description_parts.append(f'({reason})')
    reversal_description = ' - '.join(description_parts)

    reversal_entry = JournalEntry(
        entry_number=_generate_journal_entry_number('REV'),
        date=datetime.now(),
        description=reversal_description,
        entry_type='عكسي',
        reference_type='voucher_reversal',
        reference_id=voucher.id,
        reference_number=voucher.voucher_number,
        created_by=cancelled_by,
        is_posted=original_entry.is_posted,
        posted_at=datetime.now() if original_entry.is_posted else None,
        posted_by=cancelled_by if original_entry.is_posted else None,
    )

    db.session.add(reversal_entry)
    db.session.flush()

    # If ANY line in this entry is tagged with source_voucher_id, the entry
    # is shared across several vouchers (add_invoice_payment consolidates
    # every payment for one invoice into a single JE — see
    # _add_payment_lines_to_consolidated_je). Reverse only THIS voucher's
    # lines in that case; mirroring the whole entry would also reverse other
    # vouchers' payments that were never cancelled.
    #
    # Untagged lines (every line predating this column, and every JE that
    # was never part of a consolidation) still reverse in full — the
    # original, correct behaviour for a JE one voucher owns outright.
    entry_lines = [l for l in original_entry.lines if not getattr(l, 'is_deleted', False)]
    is_consolidated = any(getattr(l, 'source_voucher_id', None) is not None for l in entry_lines)
    lines_to_reverse = (
        [l for l in entry_lines if l.source_voucher_id == voucher.id]
        if is_consolidated else entry_lines
    )

    for line in lines_to_reverse:
        line_description = line.description or reversal_description
        reversal_line = JournalEntryLine(
            journal_entry_id=reversal_entry.id,
            account_id=line.account_id,
            customer_id=line.customer_id,
            supplier_id=line.supplier_id,
            cash_debit=line.cash_credit,
            cash_credit=line.cash_debit,
            debit_18k=line.credit_18k,
            credit_18k=line.debit_18k,
            debit_21k=line.credit_21k,
            credit_21k=line.debit_21k,
            debit_22k=line.credit_22k,
            credit_22k=line.debit_22k,
            debit_24k=line.credit_24k,
            credit_24k=line.debit_24k,
            debit_weight=line.credit_weight,
            credit_weight=line.debit_weight,
            gold_price_snapshot=line.gold_price_snapshot,
            description=f"عكس: {line_description}",
        )
        db.session.add(reversal_line)

    return reversal_entry

@vouchers_bp.route('/vouchers/<int:voucher_id>/cancel', methods=['POST'])
def cancel_voucher(voucher_id):
    """Cancel voucher"""
    voucher = Voucher.query.get_or_404(voucher_id)
    
    if voucher.status == 'cancelled':
        return jsonify({'error': 'Voucher is already cancelled'}), 400
    
    data = request.get_json() or {}
    reason = data.get('reason', 'No reason provided')
    cancelled_by = data.get('cancelled_by', 'system')
    
    try:
        reversal_entry = None
        if voucher.journal_entry_id:
            reversal_entry = _reverse_voucher_journal_entry(
                voucher,
                cancelled_by=cancelled_by,
                reason=reason
            )

        # Reverse SafeBox ledger movements only when a matching GL reversal JE was
        # created.  If the voucher was never posted (no JE) we must NOT append
        # voucher_reversal SBTs — they would be orphans with no GL counterpart.
        # Instead, delete any stray SBTs that already exist for this voucher.
        if reversal_entry is not None:
            _append_safe_reversal_transactions_for_voucher(
                voucher,
                created_by=cancelled_by,
                reason=f"Voucher cancel: {reason}",
            )
        else:
            SafeBoxTransaction.query.filter(
                SafeBoxTransaction.ref_type == 'voucher',
                SafeBoxTransaction.ref_id == voucher.id,
            ).delete(synchronize_session=False)

        voucher.status = 'cancelled'
        voucher.cancellation_reason = reason
        voucher.cancelled_at = datetime.now()

        # حذف صفوف SettlementLine عند إلغاء سند تسوية مقاصة -- يُعيد الدفعات
        # لقائمة "غير مسوّاة" فعلاً (لا ترك بيانات أيتام تُسبّب phantom-settled).
        # السبب: cancel_voucher يعكس القيد المحاسبي والخزينة ، لكن SettlementLine
        # لم تكن تُحذف، مما منع المجدوِّل من رؤية الدفعات كغير مسوّاة.
        # حادثة إنتاجية: AV-2026-00223 (2026-06-29) -- 5 دفعات، 21,770 ريال معلَّقة.
        if voucher.reference_type == 'clearing_settlement':
            AllocationService().unallocate(voucher)

        # Same class of bug as AV-2026-00223, for reference_type='gold_advance':
        # a cancelled advance's SupplierGoldAdvance row(s) must have their
        # GoldAllocation rows freed too, or the weight they consumed stays
        # invisibly locked against invoices it no longer really covers.
        if voucher.reference_type == 'gold_advance':
            for advance in SupplierGoldAdvance.query.filter_by(source_voucher_id=voucher.id).all():
                GoldAllocationService().unallocate(advance_id=advance.id)

        # An attribution must never outlive the payment that evidences it — the
        # same class of bug as AV-2026-00223. Safe to call unconditionally: a
        # voucher with no attribution rows removes none.
        remove_attributions_for_voucher(voucher.id)

        # Same class of bug as AV-2026-00223 above, for reference_type='invoice'
        # instead: cancel_voucher reverses the JE and SafeBox but never told the
        # invoice. InvoicePaymentStateService excludes this voucher's
        # InvoicePayment from the sum on its own (via the SafeBoxTransaction
        # link this cancellation just reversed), so recomputing here is enough
        # — no row is deleted, the historical InvoicePayment stays intact.
        if voucher.reference_type == 'invoice' and voucher.reference_id:
            try:
                linked_invoice = Invoice.query.get(int(voucher.reference_id))
                if linked_invoice is not None:
                    InvoicePaymentStateService().recompute(linked_invoice)
            except Exception as _sync_exc:
                print(f"⚠️ invoice payment-state sync after voucher cancel skipped: {_sync_exc}")

        # Audit log
        try:
            AuditLog.log_action(
                user_name=cancelled_by,
                action='cancel_voucher',
                entity_type='Voucher',
                entity_id=voucher.id,
                entity_number=voucher.voucher_number,
                details=json.dumps({'reason': reason}, ensure_ascii=False),
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=True,
            )
        except Exception:
            pass
        
        db.session.commit()
        
        response_payload = voucher.to_dict()
        if reversal_entry:
            response_payload['reversal_journal_entry'] = {
                'id': reversal_entry.id,
                'entry_number': reversal_entry.entry_number,
                'date': reversal_entry.date.isoformat() if reversal_entry.date else None
            }
        
        return jsonify(response_payload)
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to cancel voucher: {str(e)}'}), 500

@vouchers_bp.route('/vouchers/stats', methods=['GET'])
def get_vouchers_stats():
    """Get vouchers statistics"""

    # Total counts by type
    stats = {
        'total_receipt': Voucher.query.filter_by(voucher_type='receipt', status='active').count(),
        'total_payment': Voucher.query.filter_by(voucher_type='payment', status='active').count(),
        'total_adjustment': Voucher.query.filter_by(voucher_type='adjustment', status='active').count(),
    }

    # Total amounts
    # Total amounts
    receipt_cash = db.session.query(db.func.sum(Voucher.amount_cash)).filter_by(
        voucher_type='receipt', status='active'
    ).scalar() or 0

    payment_cash = db.session.query(db.func.sum(Voucher.amount_cash)).filter_by(
        voucher_type='payment', status='active'
    ).scalar() or 0
    stats['total_receipt_cash'] = float(receipt_cash)
    stats['total_payment_cash'] = float(payment_cash)
    stats['net_cash'] = float(receipt_cash - payment_cash)

    return jsonify(stats)

# ========================================
# Initialize Payment Accounts & Methods
# ========================================
@vouchers_bp.route('/initialize-payment-system', methods=['POST'])
@require_permission('system.settings')
def initialize_payment_system():
    """
    تهيئة شجرة الحسابات ووسائل الدفع الافتراضية
    يدعم الحذف الكامل وإعادة التهيئة عبر المعامل force=true
    """
    try:
        # 🆕 دعم الحذف الكامل وإعادة التهيئة
        force_reset = request.json.get('force', False) if request.json else False
        
        if force_reset:
            # حذف جميع وسائل الدفع الموجودة
            PaymentMethod.query.delete()
            db.session.commit()
            
            # حذف حسابات وسائل الدفع إذا لم تُستخدم
            payment_account_numbers = [
                '1111', '1112', '1113', '1114', '1115', '1116', '1117', '1118', '1119',
                '5111', '5112', '5113', '5114', '5115', '5116'
            ]
            for acc_num in payment_account_numbers:
                acc = Account.query.filter_by(account_number=acc_num).first()
                if acc:
                    # تحقق من عدم استخدام الحساب في قيود
                    journal_lines_count = JournalEntryLine.query.filter_by(account_id=acc.id).count()
                    if journal_lines_count == 0:
                        db.session.delete(acc)
            
            db.session.commit()
        else:
            # التحقق من وجود بيانات مسبقاً (السلوك القديم)
            existing_accounts = Account.query.filter(Account.account_number.in_([
                '1111', '1112', '1113', '1114', '1115', '1116', '1117'
            ])).count()
            
            if existing_accounts > 0:
                return jsonify({
                    'status': 'warning',
                    'message': 'Payment accounts already exist. Use {"force": true} to reset.',
                    'existing_count': existing_accounts
                }), 200
        
        # 1. إنشاء شجرة الحسابات
        accounts_data = [
            # الأصول (Assets)
            {'account_number': '1000', 'name': 'الأصول', 'type': 'asset', 'transaction_type': None},
            {'account_number': '1100', 'name': 'الأصول المتداولة', 'type': 'asset', 'transaction_type': None},
            
            # حسابات وسائل الدفع
            {'account_number': '1111', 'name': 'الصندوق (نقداً)', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1112', 'name': 'البنك - الحساب الجاري', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1113', 'name': 'بطاقة مدى - نقاط البيع', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1114', 'name': 'بطاقات فيزا/ماستركارد', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1115', 'name': 'تابي - مستحقات قصيرة الأجل', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1116', 'name': 'تمارا - مستحقات قصيرة الأجل', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1117', 'name': 'STC Pay - المحفظة الرقمية', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1118', 'name': 'Apple Pay / Google Pay', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1119', 'name': 'التحويل البنكي المباشر', 'type': 'asset', 'transaction_type': 'both'},
            
            # المصروفات (Expenses)
            {'account_number': '5000', 'name': 'المصروفات', 'type': 'expense', 'transaction_type': None},
            {'account_number': '5100', 'name': 'مصروفات التشغيل', 'type': 'expense', 'transaction_type': None},
            
            # حسابات العمولات
            {'account_number': '5111', 'name': 'عمولة البنك - بطاقة مدى', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5112', 'name': 'عمولة البنك - فيزا/ماستركارد', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5113', 'name': 'عمولة تابي (BNPL)', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5114', 'name': 'عمولة تمارا (BNPL)', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5115', 'name': 'عمولة STC Pay', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5116', 'name': 'عمولة Apple/Google Pay', 'type': 'expense', 'transaction_type': 'both'},
        ]
        
        created_accounts = []
        for acc_data in accounts_data:
            # التحقق من عدم وجود الحساب
            existing = Account.query.filter_by(account_number=acc_data['account_number']).first()
            if not existing:
                account = Account(
                    account_number=acc_data['account_number'],
                    name=acc_data['name'],
                    type=acc_data['type'],
                    transaction_type=acc_data['transaction_type']
                )
                db.session.add(account)
                created_accounts.append(acc_data['account_number'])
        
        db.session.commit()
        
        # 2. إنشاء وسائل الدفع الافتراضية
        from models import PaymentMethod
        
        payment_methods_data = [
            {'name': 'نقداً', 'commission_rate': 0.0, 'account_number': '1111', 'settlement_days': 0, 
             'notes': 'استلام فوري - لا توجد عمولات'},
            
            {'name': 'بطاقة مدى', 'commission_rate': 1.5, 'account_number': '1113', 'settlement_days': 2,
             'notes': 'عمولة 1.5% - استلام خلال يومين'},
            
            {'name': 'فيزا / ماستركارد', 'commission_rate': 2.5, 'account_number': '1114', 'settlement_days': 3,
             'notes': 'عمولة 2.5% - استلام خلال 3 أيام'},
            
            {'name': 'تابي (Tabby)', 'commission_rate': 4.0, 'account_number': '1115', 'settlement_days': 7,
             'notes': 'عمولة 4% - استلام خلال أسبوع بعد اكتمال الأقساط'},
            
            {'name': 'تمارا (Tamara)', 'commission_rate': 4.0, 'account_number': '1116', 'settlement_days': 7,
             'notes': 'عمولة 4% - استلام خلال أسبوع بعد اكتمال الأقساط'},
            
            {'name': 'STC Pay', 'commission_rate': 1.5, 'account_number': '1117', 'settlement_days': 1,
             'notes': 'عمولة 1.5% - استلام خلال يوم واحد'},
            
            {'name': 'Apple Pay', 'commission_rate': 2.0, 'account_number': '1118', 'settlement_days': 2,
             'notes': 'عمولة 2% - استلام خلال يومين'},
            
            {'name': 'تحويل بنكي', 'commission_rate': 0.0, 'account_number': '1119', 'settlement_days': 1,
             'notes': 'بدون عمولة - استلام حسب البنك (1-3 أيام)'},
        ]
        
        created_methods = []
        for method_data in payment_methods_data:
            # البحث عن الحساب المرتبط
            account = Account.query.filter_by(account_number=method_data['account_number']).first()
            
            if account:
                # التحقق من عدم وجود وسيلة الدفع
                existing_method = PaymentMethod.query.filter_by(name=method_data['name']).first()
                if not existing_method:
                    payment_method = PaymentMethod(
                        name=method_data['name'],
                        commission_rate=method_data['commission_rate'],
                        account_id=account.id,
                        settlement_days=method_data['settlement_days'],
                        notes=method_data['notes'],
                        is_active=True
                    )
                    db.session.add(payment_method)
                    created_methods.append(method_data['name'])
        
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'Payment system initialized successfully',
            'accounts_created': len(created_accounts),
            'payment_methods_created': len(created_methods),
            'details': {
                'accounts': created_accounts,
                'payment_methods': created_methods
            }
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500
    """
    إعادة تنظيم شجرة الحسابات لاستخدام Sub-Accounts
    تحويل مدى/فيزا/STC/Apple Pay لحسابات فرعية تحت البنك (1112)
    """
    try:
        # 1. حذف الحسابات المنفصلة القديمة (soft delete)
        old_accounts = ['1113', '1114', '1117', '1118']
        deleted_accounts = []
        
        for acc_num in old_accounts:
            account = Account.query.filter_by(account_number=acc_num).first()
            if account:
                # حذف الحساب
                db.session.delete(account)
                deleted_accounts.append(acc_num)
        
        # 2. إنشاء الحسابات الفرعية تحت البنك (1112)
        bank_account = Account.query.filter_by(account_number='1112').first()
        if not bank_account:
            return jsonify({
                'status': 'error',
                'message': 'حساب البنك الرئيسي (1112) غير موجود'
            }), 404
        
        sub_accounts_data = [
            {'account_number': '1112.1', 'name': 'بطاقة مدى - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.2', 'name': 'بطاقات فيزا - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.3', 'name': 'بطاقات ماستركارد - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.4', 'name': 'STC Pay - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.5', 'name': 'Apple Pay - نقاط البيع', 'parent_id': bank_account.id},
        ]
        
        created_accounts = []
        for sub_data in sub_accounts_data:
            # التحقق من عدم وجود الحساب
            existing = Account.query.filter_by(account_number=sub_data['account_number']).first()
            if not existing:
                sub_account = Account(
                    account_number=sub_data['account_number'],
                    name=sub_data['name'],
                    type='asset',
                    transaction_type='both',
                    parent_id=sub_data['parent_id']
                )
                db.session.add(sub_account)
                created_accounts.append(sub_data['account_number'])
        
        db.session.commit()
        
        # 3. تحديث وسائل الدفع للإشارة للحسابات الجديدة
        payment_mapping = {
            'بطاقة مدى': '1112.1',
            'فيزا / ماستركارد': '1112.2',  # سنفصلها لاحقاً
            'STC Pay': '1112.4',
            'Apple Pay': '1112.5',
        }
        
        updated_methods = []
        for method_name, new_account_number in payment_mapping.items():
            method = PaymentMethod.query.filter_by(name=method_name).first()
            new_account = Account.query.filter_by(account_number=new_account_number).first()
            
            if method and new_account:
                method.account_id = new_account.id
                updated_methods.append(method_name)
        
        # إضافة ماستركارد كوسيلة منفصلة
        mastercard_account = Account.query.filter_by(account_number='1112.3').first()
        existing_mastercard = PaymentMethod.query.filter_by(name='ماستركارد').first()
        
        if mastercard_account and not existing_mastercard:
            mastercard_method = PaymentMethod(
                name='ماستركارد',
                commission_rate=2.5,
                account_id=mastercard_account.id,
                settlement_days=3,
                notes='عمولة 2.5% - استلام خلال 3 أيام عبر جهاز نقاط البيع',
                is_active=True
            )
            db.session.add(mastercard_method)
            updated_methods.append('ماستركارد (جديد)')
        
        # تحديث اسم فيزا
        visa_method = PaymentMethod.query.filter_by(name='فيزا / ماستركارد').first()
        if visa_method:
            visa_method.name = 'فيزا'
            visa_account = Account.query.filter_by(account_number='1112.2').first()
            if visa_account:
                visa_method.account_id = visa_account.id
        
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'تم إعادة تنظيم شجرة الحسابات بنجاح',
            'deleted_accounts': deleted_accounts,
            'created_sub_accounts': created_accounts,
            'updated_payment_methods': updated_methods,
            'structure': {
                'main_account': '1112 - البنك - الحساب الجاري',
                'sub_accounts': [
                    '1112.1 - مدى',
                    '1112.2 - فيزا',
                    '1112.3 - ماستركارد',
                    '1112.4 - STC Pay',
                    '1112.5 - Apple Pay'
                ],
                'independent_accounts': [
                    '1111 - الصندوق (نقداً)',
                    '1115 - تابي (شركة خارجية)',
                    '1116 - تمارا (شركة خارجية)',
                    '1119 - تحويل بنكي مباشر'
                ]
            }
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500

