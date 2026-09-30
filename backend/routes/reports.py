"""Reports domain routes — reports_bp registered under /api in app.py."""
from __future__ import annotations

import json
import os
from collections import defaultdict
from datetime import date, datetime, time, timedelta

from flask import Blueprint, current_app, g, jsonify, request
from statistics import pstdev
from sqlalchemy import and_, cast, func, or_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    AuditLog,
    Customer,
    Employee,
    GoldPrice,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    InvoicePayment,
    JournalEntry,
    JournalEntryLine,
    Office,
    SafeBox,
    SafeBoxTransaction,
    Supplier,
    SystemAlert,
)
from core.database import _db_has_column
from core.dates import _parse_iso_date
from auth_decorators import get_current_user, require_auth, require_permission

from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
from pricing.karat_service import convert_to_main_karat, get_main_karat
from accounting.mappings import get_account_id_by_number, get_account_id_for_mapping
from core.settings import _get_settings_singleton
from accounting.wages import _ensure_manufacturing_wage_expense_account
from accounting.inventory import get_inventory_average_cost
from services.journals import create_wage_weight_release_journal
from services.live_balances import safe_box_balances_bulk
from utils import normalize_number
from routes import (
    _invoice_weight_mk_v2,
    _line_weight_total_in_main_karat,
)

reports_bp = Blueprint('reports', __name__)

@reports_bp.route('/reports/sales_overview', methods=['GET'])
@require_permission('employees.view')
@require_permission('reports.sales')
def get_sales_overview_report():
    """تقرير ملخص المبيعات وفق النظام الوزني"""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    group_by = (request.args.get('group_by') or 'day').lower()
    if group_by not in {'day', 'month', 'year'}:
        group_by = 'day'
    include_unposted = (request.args.get('include_unposted', 'false').lower() == 'true')
    gold_type_filter = request.args.get('gold_type')

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            # استخدم < end_dt لتجنب مشاكل المناطق الزمنية
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    sale_types = {
        'بيع': 1,
        'sell': 1,
        'sale': 1,
        'مرتجع بيع': -1,
    }

    filters = [Invoice.invoice_type.in_(sale_types.keys())]

    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))

    if gold_type_filter:
        filters.append(Invoice.gold_type == gold_type_filter)

    if start_dt:
        filters.append(Invoice.date >= start_dt)

    if end_dt:
        filters.append(Invoice.date < end_dt)

    invoices = (
        Invoice.query
        .filter(*filters)
        .options(
            joinedload(Invoice.karat_lines),
            joinedload(Invoice.items),
        )
        .order_by(Invoice.date.asc())
        .all()
    )

    main_karat = get_main_karat()

    def _calc_weight_mk(inv):
        """Wrapper محلي — يستدعي _invoice_weight_mk_v2 المشتركة."""
        return _invoice_weight_mk_v2(inv)

    summary = {
        'total_documents': len(invoices),
        'net_sales_value': 0.0,
        'gross_sales_value': 0.0,
        'returns_value': 0.0,
        'net_gold_weight': 0.0,
        'gross_gold_weight': 0.0,
        'returns_count': 0,
        'average_invoice_value': 0.0,
        'average_gold_weight': 0.0,
        'by_gold_type': {},
    }

    series_map = defaultdict(lambda: {
        'period': '',
        'documents': 0,
        'net_value': 0.0,
        'net_weight': 0.0,
        'sales_value': 0.0,
        'sales_weight': 0.0,
        'returns_value': 0.0,
        'returns_weight': 0.0,
        'returns_count': 0,
    })

    gold_type_map = defaultdict(lambda: {
        'count': 0,
        'net_value': 0.0,
        'net_weight': 0.0,
        'sales_value': 0.0,
        'returns_value': 0.0,
    })

    for invoice in invoices:
        sign = sale_types.get(invoice.invoice_type, 1)
        total_value = float(invoice.total or 0.0)
        total_weight = _calc_weight_mk(invoice)

        net_value = total_value * sign
        net_weight = total_weight * sign

        summary['net_sales_value'] += net_value
        summary['net_gold_weight'] += net_weight

        if sign > 0:
            summary['gross_sales_value'] += total_value
            summary['gross_gold_weight'] += total_weight
        else:
            summary['returns_count'] += 1
            summary['returns_value'] += total_value

        period_source = invoice.date or datetime.now()
        if group_by == 'year':
            period_key = period_source.strftime('%Y')
        elif group_by == 'month':
            period_key = period_source.strftime('%Y-%m')
        else:
            period_key = period_source.strftime('%Y-%m-%d')

        bucket = series_map[period_key]
        bucket['period'] = period_key
        bucket['documents'] += 1
        bucket['net_value'] += net_value
        bucket['net_weight'] += net_weight

        if sign > 0:
            bucket['sales_value'] += total_value
            bucket['sales_weight'] += total_weight
        else:
            bucket['returns_value'] += total_value
            bucket['returns_weight'] += total_weight
            bucket['returns_count'] += 1

        gold_key = (invoice.gold_type or 'unspecified').lower()
        gold_entry = gold_type_map[gold_key]
        gold_entry['count'] += 1
        gold_entry['net_value'] += net_value
        gold_entry['net_weight'] += net_weight
        if sign > 0:
            gold_entry['sales_value'] += total_value
        else:
            gold_entry['returns_value'] += total_value

    if summary['total_documents'] > 0:
        summary['average_invoice_value'] = summary['gross_sales_value'] / summary['total_documents']
        summary['average_gold_weight'] = summary['gross_gold_weight'] / summary['total_documents']

    # تقريب القيم النقدية والوزنية
    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    summary['net_sales_value'] = round_money(summary['net_sales_value'])
    summary['gross_sales_value'] = round_money(summary['gross_sales_value'])
    summary['returns_value'] = round_money(summary['returns_value'])
    summary['average_invoice_value'] = round_money(summary['average_invoice_value'])
    summary['net_gold_weight'] = round_weight(summary['net_gold_weight'])
    summary['gross_gold_weight'] = round_weight(summary['gross_gold_weight'])
    summary['average_gold_weight'] = round_weight(summary['average_gold_weight'])

    summary['by_gold_type'] = {
        gold_type: {
            'count': data['count'],
            'net_value': round_money(data['net_value']),
            'net_weight': round_weight(data['net_weight']),
            'sales_value': round_money(data['sales_value']),
            'returns_value': round_money(data['returns_value']),
        }
        for gold_type, data in gold_type_map.items()
    }

    series = sorted(series_map.values(), key=lambda item: item['period'])
    for row in series:
        row['net_value'] = round_money(row['net_value'])
        row['sales_value'] = round_money(row['sales_value'])
        row['returns_value'] = round_money(row['returns_value'])
        row['net_weight'] = round_weight(row['net_weight'])
        row['sales_weight'] = round_weight(row['sales_weight'])
        row['returns_weight'] = round_weight(row['returns_weight'])

    sales_case = case((Invoice.invoice_type == 'مرتجع بيع', -1), else_=1)

    top_customers_rows = (
        db.session.query(
            Customer.id,
            Customer.name,
            func.count(Invoice.id).label('documents'),
            func.coalesce(func.sum(func.coalesce(Invoice.total, 0) * sales_case), 0).label('net_value'),
            func.coalesce(func.sum(func.coalesce(Invoice.total_weight, 0) * sales_case), 0).label('net_weight'),
        )
        .join(Customer, Invoice.customer_id == Customer.id)
        .filter(*filters, Invoice.customer_id.isnot(None))
        .group_by(Customer.id, Customer.name)
        .order_by(func.sum(func.coalesce(Invoice.total, 0) * sales_case).desc())
        .limit(5)
        .all()
    )

    top_customers = [
        {
            'id': row.id,
            'name': row.name,
            'documents': int(row.documents or 0),
            'net_value': round_money(row.net_value),
            'net_weight': round_weight(row.net_weight),
        }
        for row in top_customers_rows
    ]

    return jsonify({
        'summary': summary,
        'series': series,
        'top_customers': top_customers,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'group_by': group_by,
            'include_unposted': include_unposted,
            'gold_type': gold_type_filter,
        },
        'count': len(invoices),
    })

# ============================================================================
# Reports API - Employee Scrap Ledger
# ============================================================================

@reports_bp.route('/reports/employee_scrap_ledger', methods=['GET'])
@require_permission('employees.view')
@require_permission('reports.gold_position')
def get_employee_scrap_ledger_report():
    """Legacy report endpoint.

    Previously computed scrap custody from invoices.
    Now backed by gold SafeBox ledger balances (SafeBoxTransaction) to keep a
    single source of truth after introducing gold safes.

    Query params:
    - start_date, end_date (YYYY-MM-DD) -> mapped to tx created_at range
    - include_unassigned (true/false) -> include default/main gold safe bucket

    NOTE:
    - branch_id/include_unposted are accepted for backward compatibility but are
      not applied to ledger-based balances.
    """

    start_date = request.args.get('start_date') or request.args.get('date_from')
    end_date = request.args.get('end_date') or request.args.get('date_to')
    branch_id_param = request.args.get('branch_id')
    include_unposted = (request.args.get('include_unposted', 'false').lower() == 'true')
    include_unassigned = (request.args.get('include_unassigned', 'true').lower() == 'true')

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

        branch_id = int(branch_id_param) if branch_id_param not in (None, '') else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    def round_weight(value):
        try:
            return round(float(value or 0.0), 3)
        except Exception:
            return 0.0

    def round_money(value):
        try:
            return round(float(value or 0.0), 2)
        except Exception:
            return 0.0

    main_karat = float(get_main_karat() or 21)

    # Resolve default/main gold safe (used as "unassigned" bucket).
    default_gold_safe = None
    try:
        default_gold_safe = SafeBox.get_default_by_type('gold')
    except Exception:
        default_gold_safe = None
    if default_gold_safe is None:
        try:
            default_gold_safe = (
                SafeBox.query
                .filter_by(safe_type='gold', is_active=True)
                .order_by(SafeBox.is_default.desc(), SafeBox.id.asc())
                .first()
            )
        except Exception:
            default_gold_safe = None

    def _ledger_balance_for_safe(safe_id: int) -> dict:
        if not safe_id:
            return {
                'weights_by_karat': {},
                'total_weight': 0.0,
                'total_weight_main_karat': 0.0,
                'first_date': None,
                'last_date': None,
            }

        q = SafeBoxTransaction.query.filter_by(safe_box_id=safe_id)
        if start_dt:
            q = q.filter(SafeBoxTransaction.created_at >= start_dt)
        if end_dt:
            q = q.filter(SafeBoxTransaction.created_at < end_dt)

        def _sum(field_name: str, direction: str) -> float:
            col = getattr(SafeBoxTransaction, field_name)
            return (
                q.with_entities(func.coalesce(func.sum(col), 0.0))
                .filter(SafeBoxTransaction.direction == direction)
                .scalar()
                or 0.0
            )

        w_in = {
            '18k': float(_sum('weight_18k', 'in')),
            '21k': float(_sum('weight_21k', 'in')),
            '22k': float(_sum('weight_22k', 'in')),
            '24k': float(_sum('weight_24k', 'in')),
        }
        w_out = {
            '18k': float(_sum('weight_18k', 'out')),
            '21k': float(_sum('weight_21k', 'out')),
            '22k': float(_sum('weight_22k', 'out')),
            '24k': float(_sum('weight_24k', 'out')),
        }
        w_bal = {
            k: float(w_in.get(k, 0.0) or 0.0) - float(w_out.get(k, 0.0) or 0.0)
            for k in ['18k', '21k', '22k', '24k']
        }

        total_weight = float(sum(w_bal.values()))
        total_weight_main = 0.0
        try:
            for k, grams in w_bal.items():
                karat = float(str(k).replace('k', ''))
                total_weight_main += float(convert_to_main_karat(float(grams or 0.0), karat))
        except Exception:
            total_weight_main = 0.0

        first_dt_local = q.with_entities(func.min(SafeBoxTransaction.created_at)).scalar()
        last_dt_local = q.with_entities(func.max(SafeBoxTransaction.created_at)).scalar()

        return {
            'weights_by_karat': {k: round_weight(v) for k, v in w_bal.items()},
            'total_weight': round_weight(total_weight),
            'total_weight_main_karat': round_weight(total_weight_main),
            'first_date': first_dt_local.isoformat() if first_dt_local else None,
            'last_date': last_dt_local.isoformat() if last_dt_local else None,
        }

    rows = []
    totals = {
        'invoice_count': 0,
        'total_value': 0.0,
        'total_cash_paid': 0.0,
        'weights_by_karat': {},
        'total_weight': 0.0,
        'total_weight_main_karat': 0.0,
    }

    # Employee-linked gold safes
    employees = (
        Employee.query
        .filter(Employee.gold_safe_box_id.isnot(None))
        .order_by(Employee.name.asc(), Employee.id.asc())
        .all()
    )

    for emp in employees:
        safe_id = getattr(emp, 'gold_safe_box_id', None)
        if not safe_id:
            continue
        safe = SafeBox.query.get(int(safe_id))
        if not safe:
            continue

        bal = _ledger_balance_for_safe(int(safe.id))
        row = {
            'scrap_holder_employee_id': emp.id,
            'scrap_holder_employee_name': emp.name,
            'safe_box_id': safe.id,
            'safe_box_name': safe.name,
            'invoice_count': 0,
            'total_value': 0.0,
            'total_cash_paid': 0.0,
            'weights_by_karat': dict(sorted((bal.get('weights_by_karat') or {}).items(), key=lambda item: item[0])),
            'total_weight': bal.get('total_weight', 0.0),
            'total_weight_main_karat': bal.get('total_weight_main_karat', 0.0),
            'first_date': bal.get('first_date'),
            'last_date': bal.get('last_date'),
        }
        rows.append(row)

        for k, v in (row.get('weights_by_karat') or {}).items():
            totals['weights_by_karat'][k] = float(totals['weights_by_karat'].get(k, 0.0) or 0.0) + float(v or 0.0)
        totals['total_weight'] += float(row.get('total_weight') or 0.0)
        totals['total_weight_main_karat'] += float(row.get('total_weight_main_karat') or 0.0)

    # Optional "unassigned" bucket -> main/default gold safe.
    if include_unassigned and default_gold_safe and getattr(default_gold_safe, 'id', None):
        bal = _ledger_balance_for_safe(int(default_gold_safe.id))
        row = {
            'scrap_holder_employee_id': None,
            'scrap_holder_employee_name': 'الخزنة الرئيسية (افتراضي)',
            'safe_box_id': default_gold_safe.id,
            'safe_box_name': default_gold_safe.name,
            'invoice_count': 0,
            'total_value': 0.0,
            'total_cash_paid': 0.0,
            'weights_by_karat': dict(sorted((bal.get('weights_by_karat') or {}).items(), key=lambda item: item[0])),
            'total_weight': bal.get('total_weight', 0.0),
            'total_weight_main_karat': bal.get('total_weight_main_karat', 0.0),
            'first_date': bal.get('first_date'),
            'last_date': bal.get('last_date'),
        }
        rows.append(row)
        for k, v in (row.get('weights_by_karat') or {}).items():
            totals['weights_by_karat'][k] = float(totals['weights_by_karat'].get(k, 0.0) or 0.0) + float(v or 0.0)
        totals['total_weight'] += float(row.get('total_weight') or 0.0)
        totals['total_weight_main_karat'] += float(row.get('total_weight_main_karat') or 0.0)

    for row in rows:
        row['total_value'] = round_money(row.get('total_value'))
        row['total_cash_paid'] = round_money(row.get('total_cash_paid'))
        row['total_weight'] = round_weight(row.get('total_weight'))
        row['total_weight_main_karat'] = round_weight(row.get('total_weight_main_karat'))
        row['weights_by_karat'] = {
            key: round_weight(value)
            for key, value in sorted((row.get('weights_by_karat') or {}).items(), key=lambda item: item[0])
        }

    rows.sort(key=lambda r: (r.get('total_weight_main_karat') or 0.0), reverse=True)

    totals['total_value'] = round_money(totals.get('total_value'))
    totals['total_cash_paid'] = round_money(totals.get('total_cash_paid'))
    totals['total_weight'] = round_weight(totals.get('total_weight'))
    totals['total_weight_main_karat'] = round_weight(totals.get('total_weight_main_karat'))
    totals['weights_by_karat'] = {
        key: round_weight(value)
        for key, value in sorted((totals.get('weights_by_karat') or {}).items(), key=lambda item: item[0])
    }

    return jsonify({
        'main_karat': main_karat,
        'rows': rows,
        'totals': totals,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'branch_id': branch_id,
            'include_unposted': include_unposted,
            'include_unassigned': include_unassigned,
        },
        'count': len(rows),
    })

@reports_bp.route('/reports/sales_by_customer', methods=['GET'])
@require_permission('reports.sales')
def get_sales_by_customer_report():
    """تقرير مبيعات حسب العملاء مع ملخصات وزن وقيمة"""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    limit_param = request.args.get('limit')
    order_by = (request.args.get('order_by') or 'net_value').lower()
    order_direction = (request.args.get('order_direction') or 'desc').lower()

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

        limit = int(limit_param) if limit_param else 25
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    limit = max(5, min(limit, 200))

    sale_types = {'بيع', 'sell', 'sale', 'مرتجع بيع'}

    filters = [
        Invoice.invoice_type.in_(sale_types),
        Invoice.customer_id.isnot(None),
    ]

    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))

    if start_dt:
        filters.append(Invoice.date >= start_dt)

    if end_dt:
        filters.append(Invoice.date < end_dt)

    sales_case = case((Invoice.invoice_type == 'مرتجع بيع', -1), else_=1)

    documents_expr = func.count(Invoice.id).label('documents')
    sales_value_expr = func.coalesce(
        func.sum(case((Invoice.invoice_type == 'مرتجع بيع', 0), else_=func.coalesce(Invoice.total, 0))),
        0,
    ).label('sales_value')
    returns_value_expr = func.coalesce(
        func.sum(case((Invoice.invoice_type == 'مرتجع بيع', func.coalesce(Invoice.total, 0)), else_=0)),
        0,
    ).label('returns_value')
    net_value_expr = func.coalesce(
        func.sum(func.coalesce(Invoice.total, 0) * sales_case),
        0,
    ).label('net_value')

    last_invoice_expr = func.max(Invoice.date).label('last_invoice_date')
    average_invoice_expr = func.coalesce(
        func.avg(func.coalesce(Invoice.total, 0)),
        0,
    ).label('average_invoice_value')

    # v2: أعمدة الوزن محذوفة من SQL (total_weight مضخّم) —
    # تُحسب لاحقاً عبر Python من karat_lines/items

    query = (
        db.session.query(
            Customer.id.label('customer_id'),
            Customer.name.label('customer_name'),
            Customer.customer_code.label('customer_code'),
            documents_expr,
            sales_value_expr,
            returns_value_expr,
            net_value_expr,
            last_invoice_expr,
            average_invoice_expr,
        )
        .join(Customer, Invoice.customer_id == Customer.id)
        .filter(*filters)
        .group_by(Customer.id, Customer.name, Customer.customer_code)
    )

    order_map = {
        'documents': documents_expr,
        'sales_value': sales_value_expr,
        'returns_value': returns_value_expr,
        'net_value': net_value_expr,
        'last_invoice_date': last_invoice_expr,
        'average_invoice_value': average_invoice_expr,
    }

    order_column = order_map.get(order_by, net_value_expr)
    if order_direction == 'asc':
        query = query.order_by(order_column.asc())
    else:
        query = query.order_by(order_column.desc())

    results = query.limit(limit).all()

    # ── v2: حساب الأوزان الصحيحة من karat_lines/items ──
    weight_invoices = (
        Invoice.query
        .filter(*filters)
        .options(joinedload(Invoice.karat_lines), joinedload(Invoice.items))
        .all()
    )
    from collections import defaultdict as _ddict
    cust_weight: dict = _ddict(lambda: {'sales_weight': 0.0, 'returns_weight': 0.0})
    total_sales_weight = 0.0
    total_returns_weight = 0.0
    for _inv in weight_invoices:
        _w = _invoice_weight_mk_v2(_inv)
        if (_inv.invoice_type or '') == 'مرتجع بيع':
            cust_weight[_inv.customer_id]['returns_weight'] += _w
            total_returns_weight += _w
        else:
            cust_weight[_inv.customer_id]['sales_weight'] += _w
            total_sales_weight += _w

    summary_row = (
        db.session.query(
            func.count(func.distinct(Invoice.customer_id)).label('customer_count'),
            func.count(Invoice.id).label('documents'),
            func.coalesce(func.sum(case((Invoice.invoice_type == 'مرتجع بيع', 0), else_=func.coalesce(Invoice.total, 0))), 0).label('sales_value'),
            func.coalesce(func.sum(case((Invoice.invoice_type == 'مرتجع بيع', func.coalesce(Invoice.total, 0)), else_=0)), 0).label('returns_value'),
            func.coalesce(func.sum(func.coalesce(Invoice.total, 0) * sales_case), 0).label('net_value'),
            func.coalesce(func.avg(func.coalesce(Invoice.total, 0)), 0).label('average_invoice_value'),
        )
        .filter(*filters)
        .first()
    )

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    summary = {
        'customer_count': int(summary_row.customer_count or 0),
        'documents': int(summary_row.documents or 0),
        'sales_value': round_money(summary_row.sales_value),
        'returns_value': round_money(summary_row.returns_value),
        'net_value': round_money(summary_row.net_value),
        'sales_weight': round_weight(total_sales_weight),
        'returns_weight': round_weight(total_returns_weight),
        'net_weight': round_weight(total_sales_weight - total_returns_weight),
        'average_invoice_value': round_money(summary_row.average_invoice_value),
    }

    customer_ids = [row.customer_id for row in results]
    balance_map = {}
    if customer_ids:
        customers = Customer.query.filter(Customer.id.in_(customer_ids)).all()
        for customer in customers:
            gold_balance_main = (
                convert_to_main_karat(customer.balance_gold_18k or 0, 18)
                + convert_to_main_karat(customer.balance_gold_21k or 0, 21)
                + convert_to_main_karat(customer.balance_gold_22k or 0, 22)
                + convert_to_main_karat(customer.balance_gold_24k or 0, 24)
            )
            balance_map[customer.id] = {
                'cash': round_money(customer.balance_cash),
                'gold_main_karat': round_weight(gold_balance_main),
            }

    customers_data = []
    for index, row in enumerate(results, start=1):
        balances = balance_map.get(row.customer_id, {'cash': 0.0, 'gold_main_karat': 0.0})
        cw = cust_weight[row.customer_id]
        sw = cw['sales_weight']
        rw = cw['returns_weight']
        customers_data.append({
            'rank': index,
            'customer_id': row.customer_id,
            'customer_name': row.customer_name,
            'customer_code': row.customer_code,
            'documents': int(row.documents or 0),
            'sales_value': round_money(row.sales_value),
            'returns_value': round_money(row.returns_value),
            'net_value': round_money(row.net_value),
            'sales_weight': round_weight(sw),
            'returns_weight': round_weight(rw),
            'net_weight': round_weight(sw - rw),
            'average_invoice_value': round_money(row.average_invoice_value),
            'last_invoice_date': row.last_invoice_date.isoformat() if row.last_invoice_date else None,
            'balance_cash': balances['cash'],
            'balance_gold_main_karat': balances['gold_main_karat'],
        })

    return jsonify({
        'summary': summary,
        'customers': customers_data,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'include_unposted': include_unposted,
            'limit': limit,
            'order_by': order_by,
            'order_direction': order_direction,
        },
        'count': len(customers_data),
    })

@reports_bp.route('/reports/sales_by_item', methods=['GET'])
@require_permission('reports.sales')
def get_sales_by_item_report():
    """تقرير المبيعات حسب الأصناف"""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    limit_param = request.args.get('limit')
    order_by = (request.args.get('order_by') or 'net_value').lower()
    order_direction = (request.args.get('order_direction') or 'desc').lower()

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

        limit = int(limit_param) if limit_param else 25
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    limit = max(5, min(limit, 200))

    sale_types = {'بيع', 'sell', 'sale', 'مرتجع بيع'}

    filters = [
        Invoice.invoice_type.in_(sale_types),
    ]

    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))

    if start_dt:
        filters.append(Invoice.date >= start_dt)

    if end_dt:
        filters.append(Invoice.date < end_dt)

    rows = (
        db.session.query(InvoiceItem, Invoice, Item)
        .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
        .outerjoin(Item, InvoiceItem.item_id == Item.id)
        .filter(*filters)
        .all()
    )

    main_karat = get_main_karat()

    def _parse_karat(value):
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            if isinstance(value, str):
                cleaned = value.replace('K', '').replace('k', '').replace('عيار', '').strip()
                try:
                    return float(cleaned)
                except (TypeError, ValueError):
                    return None
        return None

    def _normalize_weight(weight, karat_value):
        if weight is None:
            return 0.0
        try:
            karat_number = float(karat_value) if karat_value not in (None, 0) else float(main_karat)
        except (TypeError, ValueError):
            karat_number = float(main_karat) if main_karat else 0.0
        if not karat_number or not main_karat:
            return float(weight or 0.0)
        return (float(weight or 0.0) * karat_number) / float(main_karat)

    aggregates = {}

    for invoice_item, invoice, item in rows:
        sign = -1 if invoice.invoice_type == 'مرتجع بيع' else 1

        key = invoice_item.item_id or f"manual:{invoice_item.name or 'غير مسمى'}:{invoice_item.karat or 'unknown'}"

        if key not in aggregates:
            aggregates[key] = {
                'item_id': invoice_item.item_id,
                'item_code': getattr(item, 'item_code', None),
                'item_name': invoice_item.name or getattr(item, 'name', 'غير مسمى'),
                'karat': invoice_item.karat or getattr(item, 'karat', None),
                'documents': set(),
                'sales_value': 0.0,
                'returns_value': 0.0,
                'net_value': 0.0,
                'sales_weight': 0.0,
                'returns_weight': 0.0,
                'net_weight': 0.0,
                'sales_quantity': 0.0,
                'returns_quantity': 0.0,
                'net_quantity': 0.0,
                'last_invoice_date': None,
            }

        entry = aggregates[key]
        entry['documents'].add(invoice.id)

        quantity = float(invoice_item.quantity or 0)
        line_value = invoice_item.net
        if line_value is None:
            price = invoice_item.price or 0.0
            line_value = price * quantity
        line_value = float(line_value or 0.0)

        weight_value = invoice_item.weight
        if weight_value is None and item is not None:
            base_weight = getattr(item, 'weight', None)
            if base_weight is not None:
                if quantity > 0:
                    weight_value = base_weight * quantity
                else:
                    weight_value = base_weight
        weight_value = float(weight_value or 0.0)

        karat_value = invoice_item.karat
        if karat_value in (None, 0) and item is not None:
            karat_value = getattr(item, 'karat', None)
        karat_value = _parse_karat(karat_value) or main_karat

        normalized_weight = _normalize_weight(weight_value, karat_value)

        if sign > 0:
            entry['sales_value'] += line_value
            entry['sales_weight'] += normalized_weight
            entry['sales_quantity'] += quantity
        else:
            entry['returns_value'] += abs(line_value)
            entry['returns_weight'] += abs(normalized_weight)
            entry['returns_quantity'] += abs(quantity)

        entry['net_value'] += line_value * sign
        entry['net_weight'] += normalized_weight * sign
        entry['net_quantity'] += quantity * sign

        if not entry['last_invoice_date'] or (invoice.date and invoice.date > entry['last_invoice_date']):
            entry['last_invoice_date'] = invoice.date

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    items_data = []
    for data in aggregates.values():
        sales_weight = data['sales_weight']
        returns_weight = data['returns_weight']
        net_weight = data['net_weight']
        sales_value = data['sales_value']

        average_price_per_gram = 0.0
        if sales_weight:
            average_price_per_gram = sales_value / sales_weight if sales_weight else 0.0

        last_invoice_iso = data['last_invoice_date'].isoformat() if data['last_invoice_date'] else None

        items_data.append({
            'item_id': data['item_id'],
            'item_code': data['item_code'],
            'item_name': data['item_name'],
            'karat': data['karat'],
            'documents': len(data['documents']),
            'sales_value': round_money(data['sales_value']),
            'returns_value': round_money(data['returns_value']),
            'net_value': round_money(data['net_value']),
            'sales_weight': round_weight(sales_weight),
            'returns_weight': round_weight(returns_weight),
            'net_weight': round_weight(net_weight),
            'sales_quantity': round_weight(data['sales_quantity']),
            'returns_quantity': round_weight(data['returns_quantity']),
            'net_quantity': round_weight(data['net_quantity']),
            'average_price_per_gram': round_money(average_price_per_gram),
            'last_invoice_date': last_invoice_iso,
        })

    order_map = {
        'net_value': lambda item: item['net_value'],
        'sales_value': lambda item: item['sales_value'],
        'returns_value': lambda item: item['returns_value'],
        'net_weight': lambda item: item['net_weight'],
        'sales_weight': lambda item: item['sales_weight'],
        'returns_weight': lambda item: item['returns_weight'],
        'net_quantity': lambda item: item['net_quantity'],
        'sales_quantity': lambda item: item['sales_quantity'],
        'returns_quantity': lambda item: item['returns_quantity'],
        'documents': lambda item: item['documents'],
        'average_price_per_gram': lambda item: item['average_price_per_gram'],
        'last_invoice_date': lambda item: item['last_invoice_date'] or '',
    }

    order_key = order_map.get(order_by, order_map['net_value'])
    reverse = order_direction != 'asc'
    items_data.sort(key=order_key, reverse=reverse)

    limited_items = items_data[:limit]

    summary = {
        'item_count': len(items_data),
        'documents': sum(item['documents'] for item in items_data),
        'sales_value': round_money(sum(item['sales_value'] for item in items_data)),
        'returns_value': round_money(sum(item['returns_value'] for item in items_data)),
        'net_value': round_money(sum(item['net_value'] for item in items_data)),
        'sales_weight': round_weight(sum(item['sales_weight'] for item in items_data)),
        'returns_weight': round_weight(sum(item['returns_weight'] for item in items_data)),
        'net_weight': round_weight(sum(item['net_weight'] for item in items_data)),
        'sales_quantity': round_weight(sum(item['sales_quantity'] for item in items_data)),
        'returns_quantity': round_weight(sum(item['returns_quantity'] for item in items_data)),
        'net_quantity': round_weight(sum(item['net_quantity'] for item in items_data)),
    }

    total_sales_weight = summary['sales_weight']
    summary['average_price_per_gram'] = round_money(
        summary['sales_value'] / total_sales_weight if total_sales_weight else 0.0
    )

    return jsonify({
        'summary': summary,
        'items': limited_items,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'include_unposted': include_unposted,
            'limit': limit,
            'order_by': order_by,
            'order_direction': order_direction,
        },
        'count': len(limited_items),
    })

@reports_bp.route('/reports/sales_by_karat', methods=['GET'])
@require_permission('reports.sales')
def get_sales_by_karat_report():
    """تقرير المبيعات حسب العيار — وزن وقيمة مجمّعان لكل عيار في الفترة المحددة."""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'

    try:
        start_dt = None
        end_dt = None
        if start_date:
            start_dt = datetime.combine(_parse_iso_date(start_date, 'start_date'), datetime.min.time())
        if end_date:
            end_dt = datetime.combine(_parse_iso_date(end_date, 'end_date'), datetime.min.time()) + timedelta(days=1)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    sale_types = {'بيع', 'sell', 'sale', 'مرتجع بيع'}

    filters = [Invoice.invoice_type.in_(list(sale_types))]
    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))
    if start_dt:
        filters.append(Invoice.date >= start_dt)
    if end_dt:
        filters.append(Invoice.date < end_dt)

    invoices = (
        Invoice.query
        .filter(*filters)
        .options(joinedload(Invoice.karat_lines), joinedload(Invoice.items))
        .all()
    )

    main_karat = get_main_karat() or 21

    # {karat_int: {'sales_weight': float, 'returns_weight': float,
    #              'sales_value': float, 'returns_value': float, 'documents': set}}
    from collections import defaultdict as _dd
    by_karat: dict = _dd(lambda: {
        'sales_weight': 0.0, 'returns_weight': 0.0,
        'sales_value': 0.0, 'returns_value': 0.0,
        'documents': set(),
    })

    totals = {
        'sales_weight': 0.0, 'returns_weight': 0.0,
        'sales_value': 0.0, 'returns_value': 0.0,
        'sales_weight_main_karat': 0.0, 'returns_weight_main_karat': 0.0,
        'total_documents': 0,
    }

    for inv in invoices:
        is_return = (inv.invoice_type or '').strip() == 'مرتجع بيع'
        inv_value = float(inv.total or 0.0)

        karat_lines = getattr(inv, 'karat_lines', None) or []
        if karat_lines:
            # توزيع القيمة بالنسبة من الوزن لكل سطر عيار
            total_kl_weight = sum(float(l.weight_grams or 0) for l in karat_lines)
            for line in karat_lines:
                lw = float(line.weight_grams or 0)
                lk = int(round(float(line.karat or main_karat)))
                if lw <= 0:
                    continue
                value_share = inv_value * (lw / total_kl_weight) if total_kl_weight > 0 else 0.0
                bucket = by_karat[lk]
                if is_return:
                    bucket['returns_weight'] += lw
                    bucket['returns_value'] += value_share
                else:
                    bucket['sales_weight'] += lw
                    bucket['sales_value'] += value_share
                    bucket['documents'].add(inv.id)
        else:
            items = getattr(inv, 'items', None) or []
            # التوزيع النسبي من inv.total (شامل الضريبة) لضمان التطابق مع sales_overview.
            # نستخدم item.net كمفتاح للتناسب فقط — لا كقيمة نهائية.
            items_net_total = sum(float(getattr(ii, 'net', 0) or 0) for ii in items)
            for ii in items:
                iw = float(getattr(ii, 'weight', 0) or 0)
                ik_raw = getattr(ii, 'karat', None)
                ik = int(round(float(ik_raw))) if ik_raw else main_karat
                if iw <= 0:
                    continue
                item_net = float(getattr(ii, 'net', 0) or 0)
                if items_net_total > 0:
                    # التناسب من inv.total (شامل الضريبة) — متسق مع sales_overview
                    item_value = inv_value * (item_net / items_net_total)
                else:
                    total_items_weight = sum(float(getattr(x, 'weight', 0) or 0) for x in items)
                    item_value = inv_value * (iw / total_items_weight) if total_items_weight > 0 else 0.0
                bucket = by_karat[ik]
                if is_return:
                    bucket['returns_weight'] += iw
                    bucket['returns_value'] += item_value
                else:
                    bucket['sales_weight'] += iw
                    bucket['sales_value'] += item_value
                    bucket['documents'].add(inv.id)

            if not items:
                # فواتير بدون بنود — نستخدم total_weight كاحتياط (كما في _invoice_weight_mk_v2)
                inv_total_w = float(getattr(inv, 'total_weight', 0) or 0)
                if is_return:
                    by_karat[main_karat]['returns_value'] += inv_value
                    by_karat[main_karat]['returns_weight'] += inv_total_w
                else:
                    by_karat[main_karat]['sales_value'] += inv_value
                    by_karat[main_karat]['sales_weight'] += inv_total_w
                    if inv_value > 0 or inv_total_w > 0:
                        by_karat[main_karat]['documents'].add(inv.id)

    # بناء القائمة
    karats_list = []
    for karat_val in sorted(by_karat.keys()):
        b = by_karat[karat_val]
        sw = round(b['sales_weight'], 3)
        rw = round(b['returns_weight'], 3)
        sv = round(b['sales_value'], 2)
        rv = round(b['returns_value'], 2)
        nw = round(sw - rw, 3)
        nv = round(sv - rv, 2)
        docs = len(b['documents'])

        avg_price = round(sv / sw, 2) if sw > 0 else 0.0

        # الوزن المعادل بالعيار الرئيسي — للمقارنة مع sales_overview.net_gold_weight
        sales_weight_mk = round(float(convert_to_main_karat(sw, karat_val)), 3)
        returns_weight_mk = round(float(convert_to_main_karat(rw, karat_val)), 3)
        net_weight_mk = round(float(convert_to_main_karat(nw, karat_val)), 3)

        karats_list.append({
            'karat': karat_val,
            'karat_label': f'عيار {karat_val}',
            'documents': docs,
            'sales_weight': sw,
            'returns_weight': rw,
            'net_weight': nw,
            'sales_weight_main_karat': sales_weight_mk,
            'returns_weight_main_karat': returns_weight_mk,
            'net_weight_main_karat': net_weight_mk,
            'sales_value': sv,
            'returns_value': rv,
            'net_value': nv,
            'avg_price_per_gram': avg_price,
            'weight_share_pct': 0.0,   # يُحسب لاحقاً
        })

        totals['sales_weight'] += sw
        totals['returns_weight'] += rw
        totals['sales_weight_main_karat'] += sales_weight_mk
        totals['returns_weight_main_karat'] += returns_weight_mk
        totals['sales_value'] += sv
        totals['returns_value'] += rv
        totals['total_documents'] += docs

    # نسب الوزن
    total_nw = sum(k['net_weight'] for k in karats_list)
    for k in karats_list:
        k['weight_share_pct'] = round(
            k['net_weight'] / total_nw * 100, 1
        ) if total_nw > 0 else 0.0

    totals['net_weight'] = round(totals['sales_weight'] - totals['returns_weight'], 3)
    totals['net_weight_main_karat'] = round(totals['sales_weight_main_karat'] - totals['returns_weight_main_karat'], 3)
    totals['net_value'] = round(totals['sales_value'] - totals['returns_value'], 2)
    totals['avg_price_per_gram'] = round(
        totals['sales_value'] / totals['sales_weight'], 2
    ) if totals['sales_weight'] > 0 else 0.0

    return jsonify({
        'summary': {
            'sales_weight': round(totals['sales_weight'], 3),
            'returns_weight': round(totals['returns_weight'], 3),
            'net_weight': totals['net_weight'],
            'sales_weight_main_karat': round(totals['sales_weight_main_karat'], 3),
            'returns_weight_main_karat': round(totals['returns_weight_main_karat'], 3),
            'net_weight_main_karat': totals['net_weight_main_karat'],
            'sales_value': round(totals['sales_value'], 2),
            'returns_value': round(totals['returns_value'], 2),
            'net_value': totals['net_value'],
            'total_documents': totals['total_documents'],
            'avg_price_per_gram': totals['avg_price_per_gram'],
            'main_karat': main_karat,
        },
        'karats': karats_list,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'include_unposted': include_unposted,
        },
    })

@reports_bp.route('/reports/inventory_status', methods=['GET'])
@require_permission('reports.inventory')
def get_inventory_status_report():
    """تقرير حالة المخزون حسب الأصناف"""
    include_zero_stock = request.args.get('include_zero_stock', 'false').lower() == 'true'
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    order_by = (request.args.get('order_by') or 'market_value').lower()
    order_direction = (request.args.get('order_direction') or 'desc').lower()

    limit_param = request.args.get('limit')
    slow_days_param = request.args.get('slow_days')
    karats_param = request.args.get('karats')

    try:
        limit = int(limit_param) if limit_param else None
        if limit is not None:
            limit = max(5, min(limit, 500))
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400

    try:
        slow_days_threshold = int(slow_days_param) if slow_days_param else 45
        slow_days_threshold = max(7, min(slow_days_threshold, 365))
    except ValueError:
        return jsonify({'error': 'Invalid slow_days parameter'}), 400

    karat_filters = []
    if karats_param:
        for part in karats_param.split(','):
            value = part.strip()
            if not value:
                continue
            try:
                karat_filters.append(float(value))
            except ValueError:
                return jsonify({'error': f'Invalid karat value: {value}'}), 400

    def parse_float(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    def parse_karat(value):
        if value in (None, ''):
            return None
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            cleaned = value.lower().replace('k', '').replace('عيار', '').strip()
            cleaned = cleaned.replace(' ', '')
            if cleaned.endswith('قيراط'):
                cleaned = cleaned[:-5]
            try:
                return float(cleaned)
            except (TypeError, ValueError):
                return None
        return None

    def matches_karat(target_value):
        if not karat_filters:
            return True
        if target_value is None:
            return False
        for expected in karat_filters:
            if abs(target_value - expected) < 0.01:
                return True
        return False

    main_karat = get_main_karat() or 21

    def normalize_to_main(weight, karat_value):
        base_weight = parse_float(weight, 0.0)
        karat_number = parse_float(karat_value, 0.0) or main_karat
        if base_weight == 0:
            return 0.0
        if not main_karat:
            return base_weight
        return (base_weight * karat_number) / float(main_karat)

    items = Item.query.order_by(Item.item_code.asc()).all()
    filtered_items = [
        item for item in items
        if matches_karat(parse_karat(getattr(item, 'karat', None)))
    ]

    item_map = {item.id: item for item in filtered_items if item.id is not None}
    item_ids = list(item_map.keys())

    invoice_filters = [InvoiceItem.item_id.isnot(None)]
    if item_ids:
        invoice_filters.append(InvoiceItem.item_id.in_(item_ids))
    if not include_unposted:
        invoice_filters.append(Invoice.is_posted.is_(True))

    movement_map = {}

    def ensure_bucket(item_id):
        if item_id not in movement_map:
            movement_map[item_id] = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'incoming_quantity': 0.0,
                'incoming_weight_main': 0.0,
                'outgoing_quantity': 0.0,
                'outgoing_weight_main': 0.0,
                'incoming_value': 0.0,
                'outgoing_value': 0.0,
                'net_value': 0.0,
                'documents': set(),
                'last_movement': None,
            }
        return movement_map[item_id]

    if item_ids:
        movement_rows = (
            db.session.query(InvoiceItem, Invoice)
            .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
            .filter(*invoice_filters)
            .all()
        )
    else:
        movement_rows = []

    purchase_types = {'شراء من عميل', 'شراء'}
    sale_types = {'بيع', 'فاتورة بيع', 'sell', 'sale'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء (مورد)'}

    for invoice_item, invoice in movement_rows:
        item_id = invoice_item.item_id
        if item_id not in item_map:
            continue

        invoice_type = (invoice.invoice_type or '').strip()
        if 'مورد' in invoice_type and 'شراء' in invoice_type:
            if 'مرتجع' in invoice_type:
                invoice_type = 'مرتجع شراء (مورد)'
            else:
                invoice_type = 'شراء'

        sign = 0
        if invoice_type in purchase_types or (
            'شراء' in invoice_type and 'مرتجع' not in invoice_type
        ):
            sign = 1
        elif invoice_type in sale_types or (
            'بيع' in invoice_type and 'مرتجع' not in invoice_type
        ):
            sign = -1
        elif invoice_type in sale_return_types or (
            'مرتجع' in invoice_type and 'بيع' in invoice_type
        ):
            sign = 1
        elif invoice_type in purchase_return_types or (
            'مرتجع' in invoice_type and 'شراء' in invoice_type
        ):
            sign = -1

        if sign == 0:
            continue

        bucket = ensure_bucket(item_id)
        item_obj = item_map[item_id]

        quantity = parse_float(invoice_item.quantity, 0.0)
        line_value = invoice_item.net
        if line_value is None:
            line_value = parse_float(invoice_item.price, 0.0) * quantity
        else:
            line_value = parse_float(line_value, 0.0)

        raw_weight = invoice_item.weight
        if raw_weight is None:
            base_weight = getattr(item_obj, 'weight', None)
            if base_weight is not None:
                raw_weight = parse_float(base_weight, 0.0) * (quantity or 1)
        raw_weight = parse_float(raw_weight, 0.0)

        karat_value = parse_karat(invoice_item.karat)
        if karat_value is None:
            karat_value = parse_karat(getattr(item_obj, 'karat', None)) or main_karat

        normalized_weight = normalize_to_main(raw_weight, karat_value)

        bucket['net_quantity'] += quantity * sign
        bucket['net_weight_main'] += normalized_weight * sign
        bucket['net_value'] += line_value * sign

        if sign > 0:
            bucket['incoming_quantity'] += quantity
            bucket['incoming_weight_main'] += normalized_weight
            bucket['incoming_value'] += line_value
        else:
            bucket['outgoing_quantity'] += quantity
            bucket['outgoing_weight_main'] += normalized_weight
            bucket['outgoing_value'] += abs(line_value)

        bucket['documents'].add(invoice.id)
        if invoice.date:
            last_date = bucket.get('last_movement')
            if last_date is None or invoice.date > last_date:
                bucket['last_movement'] = invoice.date

    latest_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    price_per_gram_24k = None
    price_reference_date = None
    if latest_price:
        try:
            price_per_gram_24k = (float(latest_price.price or 0.0) / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
            price_reference_date = latest_price.date.isoformat() if latest_price.date else None
        except (TypeError, ValueError):
            price_per_gram_24k = None

    price_per_gram_main = None
    if price_per_gram_24k:
        try:
            price_per_gram_main = price_per_gram_24k * (main_karat / 24.0)
        except (TypeError, ValueError, ZeroDivisionError):
            price_per_gram_main = None

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    now = datetime.now()

    summary_totals = {
        'items_total': len(filtered_items),
        'items_in_stock': 0,
        'items_out_of_stock': 0,
        'items_negative': 0,
        'slow_moving_items': 0,
        'total_recorded_quantity': 0.0,
        'total_calculated_quantity': 0.0,
        'total_effective_quantity': 0.0,
        'total_recorded_weight_main': 0.0,
        'total_calculated_weight_main': 0.0,
        'total_effective_weight_main': 0.0,
        'total_market_value': 0.0,
        'total_tag_value': 0.0,
        'total_documents': 0,
        'latest_movement': None,
    }

    items_payload = []

    for item in filtered_items:
        item_karat = parse_karat(getattr(item, 'karat', None)) or main_karat

        recorded_stock_qty = parse_float(getattr(item, 'stock', None), 0.0)
        if recorded_stock_qty == 0:
            recorded_stock_qty = parse_float(getattr(item, 'count', None), 0.0)

        unit_weight = parse_float(getattr(item, 'weight', None), 0.0)
        recorded_total_weight = unit_weight * recorded_stock_qty if unit_weight and recorded_stock_qty else unit_weight
        recorded_weight_main = normalize_to_main(recorded_total_weight, item_karat)

        bucket = movement_map.get(item.id)
        if bucket is None:
            bucket = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'incoming_quantity': 0.0,
                'incoming_weight_main': 0.0,
                'outgoing_quantity': 0.0,
                'outgoing_weight_main': 0.0,
                'incoming_value': 0.0,
                'outgoing_value': 0.0,
                'net_value': 0.0,
                'documents': set(),
                'last_movement': None,
            }

        calculated_quantity = bucket['net_quantity']
        calculated_weight_main = bucket['net_weight_main']

        effective_quantity = calculated_quantity if abs(calculated_quantity) > 1e-6 else recorded_stock_qty
        effective_weight_main = calculated_weight_main if abs(calculated_weight_main) > 1e-6 else recorded_weight_main

        documents_count = len(bucket['documents'])
        last_movement = bucket['last_movement']
        days_since_movement = None
        if last_movement:
            try:
                days_since_movement = (now - last_movement).days
            except Exception:
                days_since_movement = None

        status = 'active'
        if effective_quantity < -1e-6 or effective_weight_main < -1e-6:
            status = 'negative_balance'
        elif abs(effective_quantity) <= 1e-6 and abs(effective_weight_main) <= 1e-6:
            status = 'out_of_stock'
        elif days_since_movement is not None and days_since_movement >= slow_days_threshold:
            status = 'slow_moving'

        slow_moving = status == 'slow_moving'

        market_value = 0.0
        if price_per_gram_main is not None:
            market_value = effective_weight_main * price_per_gram_main

        valuation_quantity = recorded_stock_qty if recorded_stock_qty > 0 else max(effective_quantity, 0.0)
        tag_value = parse_float(getattr(item, 'price', None), 0.0) * valuation_quantity
        valuation_gap = market_value - tag_value

        average_tag_price_per_gram = 0.0
        if effective_weight_main > 0:
            average_tag_price_per_gram = tag_value / effective_weight_main if effective_weight_main else 0.0

        item_entry = {
            'item_id': item.id,
            'item_code': item.item_code,
            'item_name': item.name,
            'karat': getattr(item, 'karat', None),
            'recorded_stock_quantity': round_weight(recorded_stock_qty),
            'calculated_stock_quantity': round_weight(calculated_quantity),
            'effective_stock_quantity': round_weight(effective_quantity),
            'unit_weight': round_weight(unit_weight),
            'recorded_total_weight': round_weight(recorded_total_weight),
            'calculated_total_weight_main_karat': round_weight(calculated_weight_main),
            'effective_weight_main_karat': round_weight(effective_weight_main),
            'market_value': round_money(market_value),
            'tag_value': round_money(tag_value),
            'valuation_gap': round_money(valuation_gap),
            'average_tag_price_per_gram': round_money(average_tag_price_per_gram),
            'net_value_flow': round_money(bucket['net_value']),
            'incoming_weight_main_karat': round_weight(bucket['incoming_weight_main']),
            'outgoing_weight_main_karat': round_weight(bucket['outgoing_weight_main']),
            'incoming_quantity': round_weight(bucket['incoming_quantity']),
            'outgoing_quantity': round_weight(bucket['outgoing_quantity']),
            'documents': int(documents_count),
            'last_movement_ts': last_movement.timestamp() if isinstance(last_movement, datetime) else None,
            'days_since_movement': int(days_since_movement) if days_since_movement is not None else None,
            'status': status,
            'slow_moving': bool(slow_moving),
        }

        if not include_zero_stock and (
            abs(item_entry['effective_stock_quantity']) <= 1e-6 and
            abs(item_entry['effective_weight_main_karat']) <= 1e-6
        ):
            continue

        items_payload.append(item_entry)

        if status == 'negative_balance':
            summary_totals['items_negative'] += 1
        elif status == 'out_of_stock':
            summary_totals['items_out_of_stock'] += 1
        else:
            summary_totals['items_in_stock'] += 1

        if slow_moving:
            summary_totals['slow_moving_items'] += 1

        summary_totals['total_recorded_quantity'] += max(recorded_stock_qty, 0.0)
        summary_totals['total_calculated_quantity'] += max(calculated_quantity, 0.0)
        summary_totals['total_effective_quantity'] += max(effective_quantity, 0.0)

        summary_totals['total_recorded_weight_main'] += max(recorded_weight_main, 0.0)
        summary_totals['total_calculated_weight_main'] += max(calculated_weight_main, 0.0)
        summary_totals['total_effective_weight_main'] += max(effective_weight_main, 0.0)

        summary_totals['total_market_value'] += market_value
        summary_totals['total_tag_value'] += tag_value
        summary_totals['total_documents'] += documents_count

        if last_movement:
            current_latest = summary_totals['latest_movement']
            if current_latest is None or last_movement > current_latest:
                summary_totals['latest_movement'] = last_movement

    reverse = order_direction != 'asc'

    if order_by == 'item_code':
        items_payload.sort(key=lambda item: (item.get('item_code') or '').lower(), reverse=reverse)
    elif order_by == 'item_name':
        items_payload.sort(key=lambda item: (item.get('item_name') or '').lower(), reverse=reverse)
    elif order_by == 'days_since_movement':
        sentinel = float('inf') if not reverse else float('-inf')
        items_payload.sort(
            key=lambda item: item.get('days_since_movement', sentinel)
            if item.get('days_since_movement') is not None else sentinel,
            reverse=reverse,
        )
    elif order_by == 'status':
        items_payload.sort(key=lambda item: item.get('status', ''), reverse=reverse)
    else:
        items_payload.sort(
            key=lambda item: item.get(order_by, 0.0),
            reverse=reverse,
        )

    if limit is not None:
        items_payload = items_payload[:limit]

    for item in items_payload:
        ts_value = item.pop('last_movement_ts', None)
        item['last_movement_date'] = (
            datetime.utcfromtimestamp(ts_value).isoformat() if ts_value is not None else None
        )

    latest_movement = summary_totals['latest_movement']
    days_since_latest = None
    if latest_movement:
        try:
            days_since_latest = (now - latest_movement).days
        except Exception:
            days_since_latest = None

    summary = {
        'items_total': summary_totals['items_total'],
        'items_considered': len(items_payload),
        'items_in_stock': summary_totals['items_in_stock'],
        'items_out_of_stock': summary_totals['items_out_of_stock'],
        'items_negative': summary_totals['items_negative'],
        'slow_moving_items': summary_totals['slow_moving_items'],
        'total_recorded_quantity': round_weight(summary_totals['total_recorded_quantity']),
        'total_calculated_quantity': round_weight(summary_totals['total_calculated_quantity']),
        'total_effective_quantity': round_weight(summary_totals['total_effective_quantity']),
        'total_recorded_weight_main_karat': round_weight(summary_totals['total_recorded_weight_main']),
        'total_calculated_weight_main_karat': round_weight(summary_totals['total_calculated_weight_main']),
        'total_effective_weight_main_karat': round_weight(summary_totals['total_effective_weight_main']),
        'total_market_value': round_money(summary_totals['total_market_value']),
        'total_tag_value': round_money(summary_totals['total_tag_value']),
        'valuation_gap': round_money(summary_totals['total_market_value'] - summary_totals['total_tag_value']),
        'documents_count': summary_totals['total_documents'],
        'latest_movement_date': latest_movement.isoformat() if latest_movement else None,
        'days_since_latest_movement': days_since_latest,
        'price_reference': {
            'per_gram_24k': round_money(price_per_gram_24k) if price_per_gram_24k else None,
            'per_gram_main_karat': round_money(price_per_gram_main) if price_per_gram_main else None,
            'main_karat': main_karat,
            'gold_price_date': price_reference_date,
        },
        'slow_days_threshold': slow_days_threshold,
    }

    return jsonify({
        'summary': summary,
        'items': items_payload,
        'filters': {
            'karats': karat_filters,
            'include_zero_stock': include_zero_stock,
            'include_unposted': include_unposted,
            'order_by': order_by,
            'order_direction': order_direction,
            'limit': limit,
            'slow_days_threshold': slow_days_threshold,
        },
        'count': len(items_payload),
    })

@reports_bp.route('/reports/low_stock', methods=['GET'])
@require_permission('reports.inventory')
def get_low_stock_report():
    """إرجاع الأصناف ذات المخزون المنخفض بناءً على عتبات الكمية أو الوزن."""

    include_zero_stock = request.args.get('include_zero_stock', 'false').lower() == 'true'
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    karats_param = request.args.get('karats')
    office_param = request.args.get('office_id')
    limit_param = request.args.get('limit')
    sort_by = (request.args.get('sort_by') or 'severity').lower()
    sort_direction = (request.args.get('sort_direction') or 'desc').lower()

    threshold_qty_param = request.args.get('threshold_quantity')
    threshold_weight_param = request.args.get('threshold_weight')

    try:
        threshold_quantity = float(threshold_qty_param) if threshold_qty_param else 2.0
        threshold_quantity = max(0.0, min(threshold_quantity, 1000.0))
    except ValueError:
        return jsonify({'error': 'Invalid threshold_quantity parameter'}), 400

    try:
        threshold_weight = float(threshold_weight_param) if threshold_weight_param else 15.0
        threshold_weight = max(0.0, min(threshold_weight, 2000.0))
    except ValueError:
        return jsonify({'error': 'Invalid threshold_weight parameter'}), 400

    try:
        limit = int(limit_param) if limit_param else 150
        limit = max(5, min(limit, 500))
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400

    office_id = None
    if office_param not in (None, ''):
        try:
            office_id = int(office_param)
        except ValueError:
            return jsonify({'error': 'office_id must be numeric'}), 400

    karat_filters = []
    if karats_param:
        for raw_value in karats_param.split(','):
            candidate = raw_value.strip()
            if not candidate:
                continue
            try:
                karat_filters.append(float(candidate))
            except ValueError:
                return jsonify({'error': f'Invalid karat value: {candidate}'}), 400

    def parse_float(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    def parse_karat(value):
        if value in (None, ''):
            return None
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            cleaned = value.lower().replace('k', '').replace('عيار', '').strip()
            cleaned = cleaned.replace(' ', '')
            if cleaned.endswith('قيراط'):
                cleaned = cleaned[:-5]
            try:
                return float(cleaned)
            except (TypeError, ValueError):
                return None
        return None

    def matches_karat(karat_value):
        if not karat_filters:
            return True
        if karat_value is None:
            return False
        for expected in karat_filters:
            if abs(karat_value - expected) < 0.01:
                return True
        return False

    main_karat = get_main_karat() or 21

    def normalize_to_main(weight, karat_value):
        base_weight = parse_float(weight, 0.0)
        karat_number = parse_float(karat_value, 0.0) or main_karat
        if base_weight == 0:
            return 0.0
        if not main_karat:
            return base_weight
        return (base_weight * karat_number) / float(main_karat)

    items = Item.query.order_by(Item.item_code.asc()).all()
    filtered_items = [
        item for item in items
        if matches_karat(parse_karat(getattr(item, 'karat', None)))
    ]

    if not filtered_items:
        return jsonify({
            'summary': {
                'items_considered': 0,
                'items_below_threshold': 0,
                'critical_items': 0,
                'total_shortage_quantity': 0.0,
                'total_shortage_weight': 0.0,
                'generated_at': datetime.now().isoformat(),
            },
            'items': [],
            'filters': {
                'include_zero_stock': include_zero_stock,
                'include_unposted': include_unposted,
                'karats': karat_filters,
                'office_id': office_id,
                'threshold_quantity': threshold_quantity,
                'threshold_weight': threshold_weight,
                'sort_by': sort_by,
                'sort_direction': sort_direction,
                'limit': limit,
            },
        })

    item_map = {item.id: item for item in filtered_items if item.id is not None}
    item_ids = list(item_map.keys())

    invoice_filters = [InvoiceItem.item_id.isnot(None)]
    if item_ids:
        invoice_filters.append(InvoiceItem.item_id.in_(item_ids))
    if not include_unposted:
        invoice_filters.append(Invoice.is_posted.is_(True))
    if office_id is not None:
        invoice_filters.append(Invoice.office_id == office_id)

    movement_rows = []
    if item_ids:
        movement_rows = (
            db.session.query(InvoiceItem, Invoice)
            .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
            .filter(*invoice_filters)
            .all()
        )

    purchase_types = {'شراء من عميل', 'شراء'}
    sale_types = {'بيع', 'فاتورة بيع', 'sell', 'sale'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء (مورد)'}

    def determine_direction(invoice_type):
        normalized = (invoice_type or '').strip()
        if normalized in purchase_types or (
            'شراء' in normalized and 'مرتجع' not in normalized
        ):
            return 1
        if normalized in sale_types or (
            'بيع' in normalized and 'مرتجع' not in normalized
        ):
            return -1
        if normalized in sale_return_types or (
            'مرتجع' in normalized and 'بيع' in normalized
        ):
            return 1
        if normalized in purchase_return_types or (
            'مرتجع' in normalized and 'شراء' in normalized
        ):
            return -1
        return 0

    movement_map = {}

    def ensure_bucket(item_id):
        if item_id not in movement_map:
            movement_map[item_id] = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'documents': set(),
                'last_movement': None,
            }
        return movement_map[item_id]

    for invoice_item, invoice in movement_rows:
        item_id = invoice_item.item_id
        if item_id not in item_map:
            continue

        direction = determine_direction(invoice.invoice_type)
        if direction == 0:
            continue

        bucket = ensure_bucket(item_id)
        item_obj = item_map[item_id]

        quantity = parse_float(getattr(invoice_item, 'quantity', None), 0.0)
        raw_weight = parse_float(getattr(invoice_item, 'weight', None), 0.0)
        if raw_weight == 0.0:
            base_weight = parse_float(getattr(item_obj, 'weight', None), 0.0)
            if base_weight:
                raw_weight = base_weight * (quantity or 1.0)

        karat_value = parse_karat(getattr(invoice_item, 'karat', None))
        if karat_value is None:
            karat_value = parse_karat(getattr(item_obj, 'karat', None)) or main_karat

        normalized_weight = normalize_to_main(raw_weight, karat_value)

        bucket['net_quantity'] += quantity * direction
        bucket['net_weight_main'] += normalized_weight * direction

        bucket['documents'].add(invoice.id)
        if invoice.date:
            last_date = bucket['last_movement']
            if last_date is None or invoice.date > last_date:
                bucket['last_movement'] = invoice.date

    now = datetime.now()

    def round_qty(value):
        return round(float(value or 0.0), 3)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    items_payload = []
    total_shortage_qty = 0.0
    total_shortage_weight = 0.0
    critical_count = 0
    movement_days = []

    for item in filtered_items:
        item_karat = parse_karat(getattr(item, 'karat', None)) or main_karat

        recorded_qty = parse_float(getattr(item, 'stock', None), 0.0)
        if recorded_qty == 0.0:
            recorded_qty = parse_float(getattr(item, 'count', None), 0.0)

        unit_weight = parse_float(getattr(item, 'weight', None), 0.0)
        recorded_total_weight = unit_weight * recorded_qty if unit_weight and recorded_qty else unit_weight
        recorded_weight_main = normalize_to_main(recorded_total_weight, item_karat)

        bucket = movement_map.get(item.id)
        if bucket is None:
            bucket = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'documents': set(),
                'last_movement': None,
            }

        calculated_qty = bucket['net_quantity']
        calculated_weight_main = bucket['net_weight_main']

        effective_qty = calculated_qty if abs(calculated_qty) > 1e-6 else recorded_qty
        effective_weight_main = calculated_weight_main if abs(calculated_weight_main) > 1e-6 else recorded_weight_main

        last_movement = bucket['last_movement']
        days_since_movement = None
        if last_movement:
            try:
                days_since_movement = (now - last_movement).days
                movement_days.append(days_since_movement)
            except Exception:
                days_since_movement = None

        shortage_qty = max(0.0, threshold_quantity - effective_qty)
        shortage_weight = max(0.0, threshold_weight - effective_weight_main)

        status = 'ok'
        if effective_qty <= 0.0 or effective_weight_main <= 0.0:
            status = 'critical'
            critical_count += 1
        elif shortage_qty > 0 or shortage_weight > 0:
            status = 'low'

        if status == 'ok' and not include_zero_stock:
            continue

        total_shortage_qty += shortage_qty
        total_shortage_weight += shortage_weight

        documents_count = len(bucket['documents'])
        severity_score = (shortage_weight * 1.5) + shortage_qty

        items_payload.append({
            'item_id': item.id,
            'item_code': item.item_code,
            'name': item.name,
            'karat': getattr(item, 'karat', None),
            'unit_weight': round_weight(unit_weight),
            'threshold_quantity': round_qty(threshold_quantity),
            'threshold_weight': round_weight(threshold_weight),
            'available_quantity': round_qty(effective_qty),
            'available_weight_main': round_weight(effective_weight_main),
            'shortage_quantity': round_qty(shortage_qty),
            'shortage_weight': round_weight(shortage_weight),
            'status': status,
            'severity_score': round(float(severity_score), 4),
            'documents_count': documents_count,
            'days_since_movement': days_since_movement,
            'last_movement': last_movement.isoformat() if last_movement else None,
            'price': parse_float(getattr(item, 'price', None), 0.0),
        })

    if not items_payload and include_zero_stock:
        for item in filtered_items[: min(limit, len(filtered_items))]:
            items_payload.append({
                'item_id': item.id,
                'item_code': item.item_code,
                'name': item.name,
                'karat': getattr(item, 'karat', None),
                'unit_weight': round_weight(parse_float(getattr(item, 'weight', None), 0.0)),
                'threshold_quantity': round_qty(threshold_quantity),
                'threshold_weight': round_weight(threshold_weight),
                'available_quantity': 0.0,
                'available_weight_main': 0.0,
                'shortage_quantity': round_qty(threshold_quantity),
                'shortage_weight': round_weight(threshold_weight),
                'status': 'critical',
                'severity_score': round_qty(threshold_quantity + threshold_weight),
                'documents_count': 0,
                'days_since_movement': None,
                'last_movement': None,
                'price': parse_float(getattr(item, 'price', None), 0.0),
            })

    def sort_key(entry):
        if sort_by == 'quantity':
            return entry['available_quantity']
        if sort_by == 'weight':
            return entry['available_weight_main']
        if sort_by == 'name':
            return entry['name'] or ''
        return entry['severity_score']

    reverse_sort = sort_direction != 'asc'
    items_payload.sort(key=sort_key, reverse=reverse_sort)
    items_payload = items_payload[:limit]

    avg_days_since_movement = None
    if movement_days:
        avg_days_since_movement = round(sum(movement_days) / len(movement_days), 1)

    summary = {
        'items_considered': len(filtered_items),
        'items_below_threshold': len(items_payload),
        'critical_items': critical_count,
        'total_shortage_quantity': round_qty(total_shortage_qty),
        'total_shortage_weight': round_weight(total_shortage_weight),
        'average_days_since_movement': avg_days_since_movement,
        'generated_at': datetime.now().isoformat(),
    }

    return jsonify({
        'summary': summary,
        'items': items_payload,
        'filters': {
            'include_zero_stock': include_zero_stock,
            'include_unposted': include_unposted,
            'karats': karat_filters,
            'office_id': office_id,
            'threshold_quantity': threshold_quantity,
            'threshold_weight': threshold_weight,
            'sort_by': sort_by,
            'sort_direction': sort_direction,
            'limit': limit,
        },
    })

@reports_bp.route('/reports/inventory_movement', methods=['GET'])
@require_permission('reports.inventory')
def get_inventory_movement_report():
    """تقرير حركة المخزون الزمني (وزن وقيمة)"""

    start_date_param = request.args.get('start_date')
    end_date_param = request.args.get('end_date')
    group_interval = (request.args.get('group_interval') or 'day').lower()
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    include_returns = request.args.get('include_returns', 'true').lower() == 'true'
    karats_param = request.args.get('karats')
    office_param = request.args.get('office_ids') or request.args.get('office_id')
    movements_limit_param = request.args.get('movements_limit') or request.args.get('limit')

    valid_intervals = {'day', 'week', 'month'}
    if group_interval not in valid_intervals:
        group_interval = 'day'

    try:
        start_dt = None
        end_dt = None

        if start_date_param:
            start_value = _parse_iso_date(start_date_param, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date_param:
            end_value = _parse_iso_date(end_date_param, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    now = datetime.now()
    if end_dt is None:
        end_dt = datetime.combine(now.date(), datetime.min.time()) + timedelta(days=1)
    if start_dt is None:
        start_dt = end_dt - timedelta(days=30)

    if end_dt <= start_dt:
        end_dt = start_dt + timedelta(days=1)

    try:
        movements_limit = int(movements_limit_param) if movements_limit_param else 200
    except ValueError:
        return jsonify({'error': 'Invalid movements_limit parameter'}), 400

    movements_limit = max(50, min(movements_limit, 500))

    def parse_float(value, default=0.0):
        try:
            if value in (None, ''):
                return default
            return float(value)
        except (TypeError, ValueError):
            return default

    def parse_karat(value):
        if value in (None, ''):
            return None
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            cleaned = value.lower().replace('k', '').replace('عيار', '').strip()
            cleaned = cleaned.replace(' ', '')
            if cleaned.endswith('قيراط'):
                cleaned = cleaned[:-5]
            try:
                return float(cleaned)
            except (TypeError, ValueError):
                return None
        return None

    karat_filters = []
    if karats_param:
        for raw in karats_param.split(','):
            value = raw.strip()
            if not value:
                continue
            parsed = parse_karat(value)
            if parsed is None:
                return jsonify({'error': f'Invalid karat value: {value}'}), 400
            karat_filters.append(parsed)

    def matches_karat(target_value):
        if not karat_filters:
            return True
        if target_value is None:
            return False
        for expected in karat_filters:
            if abs(target_value - expected) < 0.01:
                return True
        return False

    office_ids = []
    if office_param:
        try:
            for raw in str(office_param).split(','):
                if not raw.strip():
                    continue
                office_ids.append(int(raw.strip()))
        except ValueError:
            return jsonify({'error': 'Invalid office id value'}), 400

    main_karat = get_main_karat() or 21

    def normalize_weight(weight_value, karat_value):
        base_weight = parse_float(weight_value, 0.0)
        karat_number = parse_float(karat_value, 0.0) or main_karat
        if base_weight == 0:
            return 0.0
        if not main_karat:
            return base_weight
        return (base_weight * karat_number) / float(main_karat)

    filters = [Invoice.date >= start_dt, Invoice.date < end_dt]
    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))
    if office_ids:
        filters.append(Invoice.office_id.in_(office_ids))

    movement_rows = (
        db.session.query(InvoiceItem, Invoice, Item, Office)
        .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
        .outerjoin(Item, InvoiceItem.item_id == Item.id)
        .outerjoin(Office, Invoice.office_id == Office.id)
        .filter(*filters)
        .all()
    )

    purchase_types = {'شراء', 'شراء من عميل'}
    sale_types = {'بيع', 'فاتورة بيع', 'sell', 'sale'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء (مورد)'}

    def determine_direction(invoice_type_value: str):
        normalized = (invoice_type_value or '').strip()
        if not include_returns and 'مرتجع' in normalized:
            return 0
        if normalized in purchase_types or (
            'شراء' in normalized and 'مرتجع' not in normalized
        ):
            return 1
        if normalized in sale_types or (
            'بيع' in normalized and 'مرتجع' not in normalized
        ):
            return -1
        if normalized in sale_return_types or (
            'مرتجع' in normalized and 'بيع' in normalized
        ):
            return 1
        if normalized in purchase_return_types or (
            'مرتجع' in normalized and 'شراء' in normalized
        ):
            return -1
        return 0

    def bucket_key_for(date_value):
        if group_interval == 'week':
            return date_value - timedelta(days=date_value.weekday())
        if group_interval == 'month':
            return date_value.replace(day=1)
        return date_value

    def bucket_bounds(start_date_value):
        start_dt_value = datetime.combine(start_date_value, datetime.min.time())
        if group_interval == 'week':
            end_dt_value = start_dt_value + timedelta(days=7)
            label = f"{start_date_value.isocalendar()[0]}-W{start_date_value.isocalendar()[1]:02d}"
        elif group_interval == 'month':
            next_month = (start_date_value.replace(day=28) + timedelta(days=4)).replace(day=1)
            end_dt_value = datetime.combine(next_month, datetime.min.time())
            label = start_date_value.strftime('%Y-%m')
        else:
            end_dt_value = start_dt_value + timedelta(days=1)
            label = start_date_value.isoformat()
        return start_dt_value, end_dt_value, label

    timeline_map = {}

    def ensure_bucket(date_value):
        key = bucket_key_for(date_value)
        if key not in timeline_map:
            start_bound, end_bound, label = bucket_bounds(key)
            timeline_map[key] = {
                'label': label,
                'start': start_bound,
                'end': end_bound,
                'inbound_weight': 0.0,
                'outbound_weight': 0.0,
                'inbound_value': 0.0,
                'outbound_value': 0.0,
                'inbound_docs': set(),
                'outbound_docs': set(),
            }
        return timeline_map[key]

    summary_totals = {
        'inbound_weight': 0.0,
        'outbound_weight': 0.0,
        'net_weight': 0.0,
        'inbound_value': 0.0,
        'outbound_value': 0.0,
        'net_value': 0.0,
    }

    inbound_doc_ids = set()
    outbound_doc_ids = set()
    ledger_map = {}
    customer_ids_needed = set()
    supplier_ids_needed = set()

    for invoice_item, invoice, item, office in movement_rows:
        if not invoice:
            continue
        if invoice.date is None:
            continue

        direction_sign = determine_direction(invoice.invoice_type)
        if direction_sign == 0:
            continue

        effective_karat = parse_karat(invoice_item.karat)
        if effective_karat is None and item is not None:
            effective_karat = parse_karat(getattr(item, 'karat', None))

        if not matches_karat(effective_karat):
            continue

        raw_weight = invoice_item.weight
        quantity = parse_float(invoice_item.quantity, 0.0)

        if raw_weight is None and item is not None:
            base_weight = parse_float(getattr(item, 'weight', None), 0.0)
            if base_weight:
                raw_weight = base_weight * (quantity if quantity else 1.0)

        normalized_weight = normalize_weight(raw_weight, effective_karat)
        weight_contribution = abs(normalized_weight)

        line_value = invoice_item.net
        if line_value is None:
            line_value = parse_float(invoice_item.price, 0.0) * (quantity or 0.0)
        value_contribution = abs(parse_float(line_value, 0.0))

        direction = 'inbound' if direction_sign > 0 else 'outbound'

        bucket = ensure_bucket(invoice.date.date())
        if direction == 'inbound':
            bucket['inbound_weight'] += weight_contribution
            bucket['inbound_value'] += value_contribution
            bucket['inbound_docs'].add(invoice.id)
            summary_totals['inbound_weight'] += weight_contribution
            summary_totals['inbound_value'] += value_contribution
            inbound_doc_ids.add(invoice.id)
        else:
            bucket['outbound_weight'] += weight_contribution
            bucket['outbound_value'] += value_contribution
            bucket['outbound_docs'].add(invoice.id)
            summary_totals['outbound_weight'] += weight_contribution
            summary_totals['outbound_value'] += value_contribution
            outbound_doc_ids.add(invoice.id)

        summary_totals['net_weight'] += weight_contribution * direction_sign
        summary_totals['net_value'] += value_contribution * direction_sign

        ledger_key = (invoice.id, direction)
        if ledger_key not in ledger_map:
            ledger_map[ledger_key] = {
                'invoice_id': invoice.id,
                'invoice_type': invoice.invoice_type,
                'invoice_type_id': invoice.invoice_type_id,
                'direction': direction,
                'date': invoice.date,
                'office_id': invoice.office_id,
                'office_name': office.name if office else None,
                'customer_id': invoice.customer_id,
                'supplier_id': invoice.supplier_id,
                'weight': 0.0,
                'value': 0.0,
                'quantity': 0.0,
                'line_count': 0,
                'item_names': set(),
                'karats': set(),
            }

        ledger_entry = ledger_map[ledger_key]
        ledger_entry['weight'] += weight_contribution
        ledger_entry['value'] += value_contribution
        ledger_entry['quantity'] += abs(quantity)
        ledger_entry['line_count'] += 1

        if invoice_item.name:
            ledger_entry['item_names'].add(invoice_item.name)
        elif item is not None and getattr(item, 'name', None):
            ledger_entry['item_names'].add(item.name)

        if effective_karat is not None:
            ledger_entry['karats'].add(round(effective_karat, 3))

        if invoice.customer_id:
            customer_ids_needed.add(invoice.customer_id)
        if invoice.supplier_id:
            supplier_ids_needed.add(invoice.supplier_id)

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    timeline_payload = []
    top_inbound = None
    top_outbound = None

    for key in sorted(timeline_map.keys()):
        bucket = timeline_map[key]
        inbound_weight = round_weight(bucket['inbound_weight'])
        outbound_weight = round_weight(bucket['outbound_weight'])
        entry = {
            'label': bucket['label'],
            'start': bucket['start'].isoformat(),
            'end': bucket['end'].isoformat(),
            'inbound_weight_main_karat': inbound_weight,
            'outbound_weight_main_karat': outbound_weight,
            'net_weight_main_karat': round_weight(bucket['inbound_weight'] - bucket['outbound_weight']),
            'inbound_value': round_money(bucket['inbound_value']),
            'outbound_value': round_money(bucket['outbound_value']),
            'net_value': round_money(bucket['inbound_value'] - bucket['outbound_value']),
            'inbound_documents': len(bucket['inbound_docs']),
            'outbound_documents': len(bucket['outbound_docs']),
        }

        if inbound_weight > 0 and (not top_inbound or inbound_weight > top_inbound['inbound_weight_main_karat']):
            top_inbound = entry
        if outbound_weight > 0 and (not top_outbound or outbound_weight > top_outbound['outbound_weight_main_karat']):
            top_outbound = entry

        timeline_payload.append(entry)

    customer_name_map = {}
    if customer_ids_needed:
        customers = Customer.query.filter(Customer.id.in_(list(customer_ids_needed))).all()
        customer_name_map = {customer.id: customer.name for customer in customers}

    supplier_name_map = {}
    if supplier_ids_needed:
        suppliers = Supplier.query.filter(Supplier.id.in_(list(supplier_ids_needed))).all()
        supplier_name_map = {supplier.id: supplier.name for supplier in suppliers}

    ledger_entries = sorted(
        ledger_map.values(),
        key=lambda entry: entry['date'] or datetime.min,
        reverse=True,
    )

    movements_payload = []
    for entry in ledger_entries[:movements_limit]:
        party_name = customer_name_map.get(entry['customer_id']) if entry['customer_id'] else None
        if not party_name and entry['supplier_id']:
            party_name = supplier_name_map.get(entry['supplier_id'])

        movements_payload.append({
            'invoice_id': entry['invoice_id'],
            'invoice_type': entry['invoice_type'],
            'invoice_number': entry['invoice_type_id'],
            'direction': entry['direction'],
            'date': entry['date'].isoformat() if entry['date'] else None,
            'office_id': entry['office_id'],
            'office_name': entry['office_name'],
            'party_name': party_name,
            'line_count': entry['line_count'],
            'total_quantity': round_weight(entry['quantity']),
            'weight_main_karat': round_weight(entry['weight']),
            'value': round_money(entry['value']),
            'karats': sorted(entry['karats']),
            'sample_items': list(entry['item_names'])[:3],
        })

    net_direction = 'balanced'
    if summary_totals['net_weight'] > 0.0005:
        net_direction = 'inbound'
    elif summary_totals['net_weight'] < -0.0005:
        net_direction = 'outbound'

    summary = {
        'total_inbound_weight_main_karat': round_weight(summary_totals['inbound_weight']),
        'total_outbound_weight_main_karat': round_weight(summary_totals['outbound_weight']),
        'net_weight_main_karat': round_weight(summary_totals['net_weight']),
        'total_inbound_value': round_money(summary_totals['inbound_value']),
        'total_outbound_value': round_money(summary_totals['outbound_value']),
        'net_value': round_money(summary_totals['net_value']),
        'inbound_documents': len(inbound_doc_ids),
        'outbound_documents': len(outbound_doc_ids),
        'period_days': max(1, (end_dt - start_dt).days),
        'date_range': {
            'start': start_dt.date().isoformat(),
            'end': (end_dt - timedelta(seconds=1)).date().isoformat(),
        },
        'group_interval': group_interval,
        'top_inbound_bucket': top_inbound,
        'top_outbound_bucket': top_outbound,
        'net_direction': net_direction,
    }

    return jsonify({
        'summary': summary,
        'timeline': timeline_payload,
        'movements': movements_payload,
        'filters': {
            'start_date': start_dt.date().isoformat(),
            'end_date': (end_dt - timedelta(seconds=1)).date().isoformat(),
            'group_interval': group_interval,
            'include_unposted': include_unposted,
            'include_returns': include_returns,
            'karats': karat_filters,
            'office_ids': office_ids,
            'movements_limit': movements_limit,
        },
        'count': len(movements_payload),
    })

@reports_bp.route('/sales-race/config', methods=['GET'])
@require_permission('system.settings')
def get_sales_race_config():
    """Return the current sales race configuration (admin only)."""
    settings_row = _get_settings_singleton(create_if_missing=True)
    _default_pv = {p: {'amounts': 'all', 'points': 'all', 'share': 'all', 'team_summary': 'all'}
                   for p in ('today', 'week', 'month')}
    config = {
        'enabled': True,
        'default_period': 'today',
        'enabled_periods': ['today', 'week', 'month'],
        'points_per_gram': 10.0,
        'points_source': 'gold_weight',
        'cash_amount_per_point': 100.0,
        'points_per_invoice': 1.0,
        'allow_fallback_to_latest_period': True,
        'show_invoice_count': True,
        'show_champion': True,
        'amounts_visibility': 'all',
        'points_visibility': 'all',
        'share_visibility': 'all',
        'team_summary_visibility': 'all',
        'period_visibility': _default_pv,
        'weekly_sales_target_weight': float(
            getattr(settings_row, 'weekly_sales_target_weight', 2000.0) or 2000.0
        ),
        'monthly_sales_target_weight': float(
            getattr(settings_row, 'monthly_sales_target_weight', 8000.0) or 8000.0
        ),
    }
    raw = getattr(settings_row, 'sales_race_settings', None)
    if raw:
        try:
            parsed = raw if isinstance(raw, dict) else json.loads(raw)
            if isinstance(parsed, dict):
                for k in ('enabled', 'default_period', 'enabled_periods', 'points_per_gram',
                          'points_source', 'cash_amount_per_point', 'points_per_invoice',
                          'allow_fallback_to_latest_period', 'show_invoice_count', 'show_champion',
                          'amounts_visibility', 'points_visibility', 'share_visibility',
                          'team_summary_visibility', 'period_visibility'):
                    if k in parsed:
                        config[k] = parsed[k]
        except Exception:
            pass
    return jsonify(config)

@reports_bp.route('/sales-race/config', methods=['PUT'])
@require_permission('system.settings')
def update_sales_race_config():
    """Save sales race configuration (admin only)."""
    data = request.get_json(silent=True) or {}
    settings_row = _get_settings_singleton(create_if_missing=True)

    _default_pv_put = {p: {'amounts': 'all', 'points': 'all', 'share': 'all', 'team_summary': 'all'}
                       for p in ('today', 'week', 'month')}
    current = {
        'enabled': True,
        'default_period': 'today',
        'enabled_periods': ['today', 'week', 'month'],
        'points_per_gram': 10.0,
        'points_source': 'gold_weight',
        'cash_amount_per_point': 100.0,
        'points_per_invoice': 1.0,
        'allow_fallback_to_latest_period': True,
        'show_invoice_count': True,
        'show_champion': True,
        'amounts_visibility': 'all',
        'points_visibility': 'all',
        'share_visibility': 'all',
        'team_summary_visibility': 'all',
        'period_visibility': _default_pv_put,
    }
    raw = getattr(settings_row, 'sales_race_settings', None)
    if raw:
        try:
            parsed = raw if isinstance(raw, dict) else json.loads(raw)
            if isinstance(parsed, dict):
                current.update(parsed)
        except Exception:
            pass

    def _vis(v):
        return 'admin_only' if str(v).strip().lower() == 'admin_only' else 'all'

    if 'enabled' in data:
        current['enabled'] = bool(data['enabled'])
    if 'default_period' in data:
        p = str(data['default_period']).strip().lower()
        current['default_period'] = p if p in {'today', 'week', 'month'} else 'today'
    if 'enabled_periods' in data:
        raw_ep = data['enabled_periods']
        if isinstance(raw_ep, list):
            valid = [p for p in raw_ep if p in {'today', 'week', 'month'}]
            current['enabled_periods'] = valid if valid else ['today']
    if 'points_per_gram' in data:
        try:
            current['points_per_gram'] = max(0.0, float(data['points_per_gram']))
        except Exception:
            pass
    _valid_sources = {'gold_weight', 'profit_cash', 'sales_amount', 'invoice_count', 'sold_weight'}
    if 'points_source' in data:
        s = str(data['points_source']).strip().lower()
        current['points_source'] = s if s in _valid_sources else 'gold_weight'
    if 'cash_amount_per_point' in data:
        try:
            current['cash_amount_per_point'] = max(0.01, float(data['cash_amount_per_point']))
        except Exception:
            pass
    if 'points_per_invoice' in data:
        try:
            current['points_per_invoice'] = max(0.0, float(data['points_per_invoice']))
        except Exception:
            pass
    if 'allow_fallback_to_latest_period' in data:
        current['allow_fallback_to_latest_period'] = bool(data['allow_fallback_to_latest_period'])
    if 'show_invoice_count' in data:
        current['show_invoice_count'] = bool(data['show_invoice_count'])
    if 'show_champion' in data:
        current['show_champion'] = bool(data['show_champion'])
    if 'amounts_visibility' in data:
        current['amounts_visibility'] = _vis(data['amounts_visibility'])
    if 'points_visibility' in data:
        current['points_visibility'] = _vis(data['points_visibility'])
    if 'share_visibility' in data:
        current['share_visibility'] = _vis(data['share_visibility'])
    if 'team_summary_visibility' in data:
        current['team_summary_visibility'] = _vis(data['team_summary_visibility'])
    if 'period_visibility' in data:
        _pv_in = data['period_visibility']
        if isinstance(_pv_in, dict):
            _pv_current = current.get('period_visibility') or {}
            _vis_keys = ('amounts', 'points', 'share', 'team_summary')
            for _p in ('today', 'week', 'month'):
                if _p in _pv_in and isinstance(_pv_in[_p], dict):
                    _pv_current[_p] = {
                        k: _vis(_pv_in[_p].get(k, 'all'))
                        for k in _vis_keys
                    }
            current['period_visibility'] = _pv_current
    if 'weekly_sales_target_weight' in data:
        try:
            settings_row.weekly_sales_target_weight = max(
                0.0, float(data['weekly_sales_target_weight'] or 0.0)
            )
        except Exception:
            pass
    if 'monthly_sales_target_weight' in data:
        try:
            settings_row.monthly_sales_target_weight = max(
                0.0, float(data['monthly_sales_target_weight'] or 0.0)
            )
        except Exception:
            pass

    # Read values we need in the response BEFORE commit (attributes expire after commit).
    _weekly = float(getattr(settings_row, 'weekly_sales_target_weight', 2000.0) or 2000.0)
    _monthly = float(getattr(settings_row, 'monthly_sales_target_weight', 8000.0) or 8000.0)
    _row_id = settings_row.id

    from sqlalchemy.orm.attributes import flag_modified as _flag_modified
    settings_row.sales_race_settings = json.dumps(current, ensure_ascii=False)
    _flag_modified(settings_row, 'sales_race_settings')

    try:
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'commit_failed', 'message': str(e)}), 500

    result = dict(current)
    result['weekly_sales_target_weight'] = _weekly
    result['monthly_sales_target_weight'] = _monthly
    return jsonify(result)

@reports_bp.route('/home/leaderboard', methods=['GET'])
def get_home_leaderboard():
    """Gamification leaderboard (safe for employees).

    Contract:
    - Query Params: period=today|week, metric=weight|count|points
    - Uses posted sales invoices for weight/count and sales+purchases for points
    - Excludes returns in phase 1
    - Admin summary is included only for admins/financial report viewers
    """
    from sqlalchemy import case, func

    period = (request.args.get('period') or 'today').strip().lower()
    metric = (request.args.get('metric') or 'weight').strip().lower()
    requested_period = period

    sales_race_config = {
        'enabled': True,
        'default_period': 'today',
        'enabled_periods': ['today', 'week', 'month'],
        'points_per_gram': 10.0,
        'allow_fallback_to_latest_period': True,
        'show_invoice_count': True,
        'show_champion': True,
        'amounts_visibility': 'all',
        'points_visibility': 'all',
        'share_visibility': 'all',
        'team_summary_visibility': 'all',
    }
    # Use _get_settings_singleton to ensure the canonical settings row is read
    # (not an arbitrary first() row which may differ in multi-row databases).
    try:
        settings_row = _get_settings_singleton(create_if_missing=False)
    except Exception:
        settings_row = None

    if settings_row and getattr(settings_row, 'sales_race_settings', None):
        try:
            _raw_src = settings_row.sales_race_settings
            parsed_sales_race = _raw_src if isinstance(_raw_src, dict) else json.loads(_raw_src)
            if isinstance(parsed_sales_race, dict):
                sales_race_config.update(parsed_sales_race)
        except Exception:
            pass

    # ── Compute caller identity early (needed for visibility checks) ──────────
    # reports_bp has no before_request; read the token directly when g.current_user
    # is absent (e.g. the app-level bypass exits early on Authorization headers).
    _lb_user = getattr(g, 'current_user', None)
    if _lb_user is None:
        try:
            from auth_decorators import get_current_user as _gcv
            _lb_user = _gcv()
        except Exception:
            _lb_user = None
    _can_view_admin = bool(getattr(_lb_user, 'is_admin', False))
    if not _can_view_admin and _lb_user is not None:
        try:
            _can_view_admin = bool(_lb_user.has_permission('reports.financial'))
        except Exception:
            _can_view_admin = False

    # ── Visibility flags ──────────────────────────────────────────────────────
    _enabled_periods = sales_race_config.get('enabled_periods') or ['today', 'week', 'month']
    if not isinstance(_enabled_periods, list):
        _enabled_periods = ['today', 'week', 'month']
    _enabled_periods = [p for p in _enabled_periods if p in {'today', 'week', 'month'}]
    if not _enabled_periods:
        _enabled_periods = ['today']

    default_period = str(sales_race_config.get('default_period') or 'today').strip().lower()
    if default_period not in {'today', 'week', 'month'}:
        default_period = 'today'
    # If the default_period is not in enabled_periods, use the first enabled one.
    if default_period not in _enabled_periods:
        default_period = _enabled_periods[0]
    if period not in _enabled_periods:
        period = default_period

    # Resolve visibility per-period first, fall back to flat global settings.
    _period_vis = (sales_race_config.get('period_visibility') or {}).get(period, {})

    def _resolve_vis(key: str) -> bool:
        per_period = _period_vis.get(key)
        if per_period:
            return per_period == 'all'
        return sales_race_config.get(f'{key}_visibility', 'all') == 'all'

    can_view_amounts      = _can_view_admin or _resolve_vis('amounts')
    can_view_points       = _can_view_admin or _resolve_vis('points')
    can_view_share        = _can_view_admin or _resolve_vis('share')
    can_view_team_summary = _can_view_admin or _resolve_vis('team_summary')

    try:
        points_per_gram = max(0.0, float(sales_race_config.get('points_per_gram') or 10.0))
    except Exception:
        points_per_gram = 10.0

    from metrics import MetricFactory
    from points.models import PointRule
    if metric not in MetricFactory.valid_names():
        metric = 'weight'

    _point_rules: list[PointRule] = []
    for _r in (sales_race_config.get('point_rules') or []):
        if not isinstance(_r, dict):
            continue
        try:
            _point_rules.append(PointRule(
                category_id=_r.get('category_id'),
                karat=float(_r['karat']) if _r.get('karat') is not None else None,
                multiplier=float(_r.get('multiplier', points_per_gram)),
            ))
        except (ValueError, TypeError, KeyError):
            pass

    _points_source         = str(sales_race_config.get('points_source') or 'gold_weight')
    _cash_amount_per_point = max(0.01, float(sales_race_config.get('cash_amount_per_point') or 100.0))
    _points_per_invoice    = max(0.0,  float(sales_race_config.get('points_per_invoice') or 1.0))

    metric_obj = MetricFactory.create(
        metric, points_per_gram,
        rules=_point_rules,
        points_source=_points_source,
        cash_amount_per_point=_cash_amount_per_point,
        points_per_invoice=_points_per_invoice,
    )
    leaderboard_invoice_types = metric_obj.invoice_types

    def _resolve_period_bounds(period_value: str, anchor_dt: datetime | None = None):
        ref = anchor_dt or datetime.now()
        normalized = (period_value or 'today').strip().lower()
        if normalized == 'week':
            start_date = ref.date() - timedelta(days=ref.date().weekday())
            start_value = datetime.combine(start_date, datetime.min.time())
            end_value = start_value + timedelta(days=7)
            return normalized, start_value, end_value

        if normalized == 'month':
            start_date = ref.date().replace(day=1)
            start_value = datetime.combine(start_date, datetime.min.time())
            # أول يوم الشهر القادم
            if start_date.month == 12:
                end_value = datetime(start_date.year + 1, 1, 1)
            else:
                end_value = datetime(start_date.year, start_date.month + 1, 1)
            return 'month', start_value, end_value

        start_value = datetime.combine(ref.date(), datetime.min.time())
        end_value = start_value + timedelta(days=1)
        return 'today', start_value, end_value

    period, start_dt, end_dt = _resolve_period_bounds(period)

    is_fallback = False
    effective_period = period
    effective_source_date = start_dt.date().isoformat() if start_dt else None

    has_activity_in_period = (
        db.session.query(Invoice.id)
        .filter(
            Invoice.is_posted.is_(True),
            Invoice.invoice_type.in_(leaderboard_invoice_types),
            Invoice.date >= start_dt,
            Invoice.date < end_dt,
        )
        .first()
        is not None
    )

    if not has_activity_in_period and bool(sales_race_config.get('allow_fallback_to_latest_period', True)):
        latest_activity_dt = (
            db.session.query(func.max(Invoice.date))
            .filter(
                Invoice.is_posted.is_(True),
                Invoice.invoice_type.in_(leaderboard_invoice_types),
            )
            .scalar()
        )
        if latest_activity_dt is not None:
            effective_period, start_dt, end_dt = _resolve_period_bounds(period, latest_activity_dt)
            effective_source_date = latest_activity_dt.date().isoformat()
            is_fallback = True

    # NOTE: For `metric=points`, employee attribution uses posted_by fallback,
    # so employee_id is not required at the DB level.
    base_filters = [
        Invoice.is_posted.is_(True),
        Invoice.date >= start_dt,
        Invoice.date < end_dt,
        Invoice.invoice_type.in_(metric_obj.invoice_types),
    ]
    if metric_obj.require_employee_id:
        base_filters.append(Invoice.employee_id.isnot(None))

    def _to_float(value, default=0.0):
        if value in (None, '', False):
            return default
        try:
            return float(value)
        except Exception:
            return default

    ranking_raw, _metric_aux = metric_obj.collect(base_filters, points_per_gram)
    metric_key = metric_obj.key

    for it in ranking_raw:
        it['score'] = metric_obj.extract_score(it)

    ranking_raw.sort(key=lambda x: (x.get('score', 0.0), x.get('count', 0)), reverse=True)

    # Sum of individual employee points — used later to keep admin_summary and
    # team_points consistent with what is actually displayed per employee.
    _sum_individual_points = sum(
        max(0, int(it.get('points', 0) or 0)) for it in ranking_raw
    )

    total_score = sum(float(it.get('score') or 0.0) for it in ranking_raw) or 0.0

    # ── جلب بيانات الأهداف الشخصية لكل موظف (دفعة واحدة) ─────────────────
    _ranking_ids = [it['id'] for it in ranking_raw]
    _emp_by_id = {}
    try:
        _emps = Employee.query.filter(Employee.id.in_(_ranking_ids)).all()
        _emp_by_id = {e.id: e for e in _emps}
    except Exception:
        pass

    # خريطة الهدف حسب الفترة والمقياس — لا احتياط بين الفترات:
    # إذا لم يُضبط هدف لهذه الفترة تحديداً تُرجع null ولا تظهر حلقة.
    _goal_attr_map = {
        ('today', 'points'):  'goal_points_daily',
        ('today', 'weight'):  'goal_weight_daily',
        ('today', 'count'):   'goal_invoices_daily',
        ('week',  'points'):  'goal_points_weekly',
        ('week',  'weight'):  'goal_weight_weekly',
        ('week',  'count'):   'goal_invoices_weekly',
        ('month', 'points'):  'goal_points_monthly',
        ('month', 'weight'):  'goal_weight_monthly',
        ('month', 'count'):   'goal_invoices_monthly',
    }
    _goal_attr = _goal_attr_map.get((period, metric))

    ranking = []
    for it in ranking_raw:
        score_value = float(it.get('score') or 0.0)
        share = (score_value / total_score) if total_score > 0 else 0.0

        # تقدم الهدف — خاص بالفترة المعروضة فقط، بدون نسبة مقيّدة بـ 1.0
        goal_target = None
        goal_progress = None
        if _goal_attr:
            emp = _emp_by_id.get(it['id'])
            if emp:
                raw_t = getattr(emp, _goal_attr, None)
                if raw_t is not None:
                    try:
                        t = float(raw_t)
                        if t > 0:
                            goal_target = round(t, 2)
                            # نسبة حقيقية — قد تتجاوز 1.0 إذا تخطّى الهدف
                            goal_progress = round(score_value / t, 4)
                    except Exception:
                        pass

        row_entry = {
            'id': it['id'],
            'name': it['name'],
            'photo': it.get('photo'),
            'count': int(it.get('count') or 0),
            'score': round(score_value, metric_obj.score_precision),
            'goal_target': goal_target,
            'goal_progress': goal_progress,
        }
        if can_view_amounts:
            row_entry['sales_amount'] = round(_to_float(it.get('sales_amount', 0.0), 0.0), 2)
            row_entry['purchase_amount'] = round(_to_float(it.get('purchase_amount', 0.0), 0.0), 2)
        if can_view_points:
            row_entry['points_sales'] = int(it.get('points_sales') or 0)
            row_entry['points_purchase'] = int(it.get('points_purchase') or 0)
        if can_view_share:
            row_entry['share'] = round(float(share), 4)
        # Unattributed entries (negative IDs from unresolved posted_by) are
        # visible to admins only — employees see a clean list of real staff.
        if int(it.get('id', 0) or 0) < 0 and not _can_view_admin:
            continue
        ranking.append(row_entry)

    # Recompute after visibility filtering so total always = sum of displayed cards.
    _display_total_points = sum(max(0, int(r.get('score', 0) or 0)) for r in ranking)

    champion = None
    if ranking and bool(sales_race_config.get('show_champion', True)):
        champion = {
            'id': ranking[0]['id'],
            'name': ranking[0]['name'],
            'badge': '🥇',
        }

    # Phase 2: weekly/monthly team goal
    target_progress = 0.0
    team_weight_g = None
    weekly_target_weight_g = None
    remaining_weight_g = None

    team_points = None
    weekly_target_points = None
    remaining_points = None

    if period in ('week', 'month'):
        team_weight_g, team_points = metric_obj.compute_team_weight(
            base_filters, points_per_gram, _metric_aux
        )
        # Override team_points with the sum of individually-computed employee
        # points so that the progress bar matches the leaderboard cards.
        if _sum_individual_points > 0:
            team_points = _sum_individual_points

        if settings_row is None:
            try:
                settings_row = _get_settings_singleton(create_if_missing=True)
            except Exception:
                settings_row = None

        if period == 'month':
            _target_attr = 'monthly_sales_target_weight'
            _default_target = 8000.0
        else:
            _target_attr = 'weekly_sales_target_weight'
            _default_target = 2000.0

        weekly_target_weight_g = _to_float(
            getattr(settings_row, _target_attr, None) if settings_row else None,
            _default_target,
        )
        if weekly_target_weight_g < 0:
            weekly_target_weight_g = 0.0

        weekly_target_points = int(round(float(weekly_target_weight_g) * points_per_gram))

        if weekly_target_weight_g > 0:
            target_progress = float(team_weight_g / weekly_target_weight_g)
            target_progress = max(0.0, min(1.0, target_progress))
            remaining_weight_g = round(max(0.0, weekly_target_weight_g - team_weight_g), 3)
            if team_points is None:
                team_points = int(round(float(team_weight_g) * points_per_gram))
            remaining_points = max(0, int(weekly_target_points or 0) - int(team_points or 0))
        else:
            target_progress = 0.0
            remaining_weight_g = 0.0
            remaining_points = 0

    payload = {
        'period': period,
        'requested_period': requested_period,
        'metric': metric_key,
        'config': {
            'enabled': bool(sales_race_config.get('enabled', True)),
            'default_period': default_period,
            'enabled_periods': _enabled_periods,
            'points_per_gram': points_per_gram,
            'allow_fallback_to_latest_period': bool(sales_race_config.get('allow_fallback_to_latest_period', True)),
            'show_invoice_count': bool(sales_race_config.get('show_invoice_count', True)),
            'show_champion': bool(sales_race_config.get('show_champion', True)),
            'amounts_visible': can_view_amounts,
            'points_visible': can_view_points,
            'share_visible': can_view_share,
        },
        'champion': champion,
        'ranking': ranking,
        'is_fallback': is_fallback,
        'effective_period': effective_period,
        'effective_start_date': start_dt.date().isoformat() if start_dt else None,
        'effective_source_date': effective_source_date,
        'target_progress': target_progress,
        'team_weight_g': team_weight_g,
        'weekly_target_weight_g': weekly_target_weight_g,
        'remaining_weight_g': remaining_weight_g,
        'team_points': team_points,
        'weekly_target_points': weekly_target_points,
        'remaining_points': remaining_points,
    }

    # Admin summary visibility is controlled by team_summary_visibility setting.
    # Profit is always admin-only regardless of settings.
    can_view_total_cash = can_view_team_summary
    can_view_total_profit = _can_view_admin

    if can_view_total_cash or can_view_total_profit:
        # Aggregate across posted sales and purchases for the same period.
        totals = (
            db.session.query(
                func.coalesce(
                    func.sum(case((Invoice.invoice_type == 'بيع', Invoice.total), else_=0.0)),
                    0.0,
                ).label('sales_total'),
                func.coalesce(
                    func.sum(case((Invoice.invoice_type == 'شراء من عميل', Invoice.total), else_=0.0)),
                    0.0,
                ).label('purchase_total'),
                func.coalesce(
                    func.sum(
                        case(
                            (Invoice.invoice_type.in_(['بيع', 'شراء من عميل']), Invoice.profit_gold),
                            else_=0.0,
                        )
                    ),
                    0.0,
                ).label('points_profit_gold_total'),
                func.coalesce(
                    func.sum(case((Invoice.invoice_type == 'بيع', Invoice.profit_cash), else_=0.0)),
                    0.0,
                ).label('profit_total'),
            )
            .filter(
                Invoice.is_posted.is_(True),
                Invoice.invoice_type.in_(['بيع', 'شراء من عميل']),
                Invoice.date >= start_dt,
                Invoice.date < end_dt,
            )
            .first()
        )
        summary_payload = {'currency': 'SAR'}
        if can_view_total_cash:
            total_sales_amount = round(_to_float(getattr(totals, 'sales_total', 0.0), 0.0), 2)
            total_purchase_amount = round(_to_float(getattr(totals, 'purchase_total', 0.0), 0.0), 2)
            summary_payload['total_cash'] = total_sales_amount
            summary_payload['total_sales_amount'] = total_sales_amount
            summary_payload['total_purchase_amount'] = total_purchase_amount
            # Use sum of the filtered ranking so the summary card always matches
            # exactly what is visible to the current user.
            summary_payload['total_points'] = _display_total_points
        if can_view_total_profit:
            summary_payload['total_profit'] = round(_to_float(getattr(totals, 'profit_total', 0.0), 0.0), 2)
        payload['admin_summary'] = summary_payload

    return jsonify(payload)

@reports_bp.route('/general_ledger_all', methods=['GET'])
@require_permission('reports.financial')
def get_general_ledger_all():
    """
    دفتر الأستاذ العام - عرض جميع الحركات
    Query Parameters:
    - account_id: تصفية حسب الحساب
    - start_date: تاريخ البداية (YYYY-MM-DD)
    - end_date: تاريخ النهاية (YYYY-MM-DD)
    - show_balances: عرض الأرصدة التراكمية (true/false)
    - karat_detail: عرض تفاصيل الأعيرة (true/false)
    """
    account_id = request.args.get('account_id', type=int)
    start_date_param = request.args.get('start_date')
    end_date_param = request.args.get('end_date')
    show_balances = request.args.get('show_balances', 'true').lower() == 'true'
    karat_detail = request.args.get('karat_detail', 'false').lower() == 'true'
    posted_only = request.args.get('posted_only', 'false').lower() == 'true'
    reference_types_param = request.args.get('reference_types')
    single_reference_type = request.args.get('reference_type')
    created_by_param = request.args.get('created_by')
    posted_by_param = request.args.get('posted_by')
    user_param = request.args.get('user')
    branch_param = request.args.get('branch') or request.args.get('branch_name')

    # Parse/validate date filters
    try:
        start_value = _parse_iso_date(start_date_param, 'start_date') if start_date_param else None
        end_value = _parse_iso_date(end_date_param, 'end_date') if end_date_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    start_dt = datetime.combine(start_value, datetime.min.time()) if start_value else None
    end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1) if end_value else None

    if start_dt and end_dt and end_dt <= start_dt:
        end_dt = start_dt + timedelta(days=1)

    reference_filters = []
    if single_reference_type:
        value = single_reference_type.strip()
        if value:
            reference_filters.append(value)
    if reference_types_param:
        for raw in str(reference_types_param).split(','):
            value = raw.strip()
            if value:
                reference_filters.append(value)
    if reference_filters:
        # إزالة التكرارات مع الحفاظ على الترتيب
        seen = []
        for value in reference_filters:
            if value not in seen:
                seen.append(value)
        reference_filters = seen

    query = (
        JournalEntryLine.query
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .join(Account, Account.id == JournalEntryLine.account_id)
        .options(
            joinedload(JournalEntryLine.account).joinedload(Account.safe_boxes),
            joinedload(JournalEntryLine.journal_entry),
        )
        .filter(JournalEntryLine.is_deleted == False)
        .filter(JournalEntry.is_deleted == False)
    )

    if account_id:
        query = query.filter(JournalEntryLine.account_id == account_id)
    if start_dt:
        query = query.filter(JournalEntry.date >= start_dt)
    if end_dt:
        query = query.filter(JournalEntry.date < end_dt)
    if posted_only:
        query = query.filter(JournalEntry.is_posted == True)
    if reference_filters:
        query = query.filter(JournalEntry.reference_type.in_(reference_filters))
    if created_by_param:
        query = query.filter(JournalEntry.created_by == created_by_param)
    if posted_by_param:
        query = query.filter(JournalEntry.posted_by == posted_by_param)
    if user_param:
        query = query.filter(or_(
            JournalEntry.created_by == user_param,
            JournalEntry.posted_by == user_param,
        ))

    branch_normalized = None
    if branch_param:
        branch_normalized = branch_param.strip().lower()
        if branch_normalized:
            query = query.outerjoin(SafeBox, SafeBox.account_id == Account.id)
            query = query.filter(
                func.lower(func.coalesce(SafeBox.branch, '')) == branch_normalized
            )

    # ── Pagination ────────────────────────────────────────────────────────────
    # بدون فلتر حساب → نفرض حداً افتراضياً 2000 صف لتجنب 502 Bad Gateway.
    # بفلتر حساب واحد يمكن رفع الحد دون خطر.
    DEFAULT_LIMIT = 2000
    MAX_LIMIT     = 10000
    try:
        per_page = min(int(request.args.get('per_page', DEFAULT_LIMIT)), MAX_LIMIT)
    except (ValueError, TypeError):
        per_page = DEFAULT_LIMIT
    try:
        page = max(1, int(request.args.get('page', 1)))
    except (ValueError, TypeError):
        page = 1

    total_count = query.count()
    lines = (
        query
        .order_by(JournalEntry.date.asc(), JournalEntry.id.asc(), JournalEntryLine.id.asc())
        .limit(per_page)
        .offset((page - 1) * per_page)
        .all()
    )

    running_cash_balance = 0.0
    running_gold_18k = 0.0
    running_gold_21k = 0.0
    running_gold_22k = 0.0
    running_gold_24k = 0.0
    total_cash_debit = 0.0
    total_cash_credit = 0.0
    total_gold_debit_normalized = 0.0
    total_gold_credit_normalized = 0.0

    entries_payload = []

    for line in lines:
        gold_debit_normalized = _line_weight_total_in_main_karat(line, 'debit')
        gold_credit_normalized = _line_weight_total_in_main_karat(line, 'credit')

        cash_debit = float(line.cash_debit or 0.0)
        cash_credit = float(line.cash_credit or 0.0)

        total_cash_debit += cash_debit
        total_cash_credit += cash_credit
        total_gold_debit_normalized += gold_debit_normalized
        total_gold_credit_normalized += gold_credit_normalized

        running_cash_balance += cash_debit - cash_credit
        running_gold_18k += (line.debit_18k or 0.0) - (line.credit_18k or 0.0)
        running_gold_21k += (line.debit_21k or 0.0) - (line.credit_21k or 0.0)
        running_gold_22k += (line.debit_22k or 0.0) - (line.credit_22k or 0.0)
        running_gold_24k += (line.debit_24k or 0.0) - (line.credit_24k or 0.0)

        account_branch = None
        if line.account and getattr(line.account, 'safe_boxes', None):
            for safe_box in line.account.safe_boxes:
                if safe_box and safe_box.branch:
                    account_branch = safe_box.branch
                    break

        entry_data = {
            'id': line.id,
            'journal_entry_id': line.journal_entry_id,
            'journal_entry_number': line.journal_entry.entry_number if line.journal_entry else None,
            'date': line.journal_entry.date.isoformat() if line.journal_entry and line.journal_entry.date else None,
            'description': (line.journal_entry.description if line.journal_entry else None) or line.description,
            'entry_type': line.journal_entry.entry_type if line.journal_entry else None,
            'account_id': line.account_id,
            'account_name': line.account.name if line.account else 'حساب غير معروف',
            'account_number': line.account.account_number if line.account else None,
            'account_branch': account_branch,
            'reference_type': line.journal_entry.reference_type if line.journal_entry else None,
            'reference_number': line.journal_entry.reference_number if line.journal_entry else None,
            'is_posted': bool(line.journal_entry.is_posted) if line.journal_entry else False,
            'created_by': line.journal_entry.created_by if line.journal_entry else None,
            'posted_by': line.journal_entry.posted_by if line.journal_entry else None,
            'cash_debit': round(cash_debit, 2),
            'cash_credit': round(cash_credit, 2),
            'gold_debit': round(gold_debit_normalized, 3),
            'gold_credit': round(gold_credit_normalized, 3),
        }

        if karat_detail:
            entry_data['karat_details'] = {
                '18k': {
                    'debit': round(float(line.debit_18k or 0.0), 3),
                    'credit': round(float(line.credit_18k or 0.0), 3),
                },
                '21k': {
                    'debit': round(float(line.debit_21k or 0.0), 3),
                    'credit': round(float(line.credit_21k or 0.0), 3),
                },
                '22k': {
                    'debit': round(float(line.debit_22k or 0.0), 3),
                    'credit': round(float(line.credit_22k or 0.0), 3),
                },
                '24k': {
                    'debit': round(float(line.debit_24k or 0.0), 3),
                    'credit': round(float(line.credit_24k or 0.0), 3),
                },
            }

        if show_balances:
            entry_data['running_balance'] = {
                'cash': round(running_cash_balance, 2),
                'gold_normalized': round(
                    convert_to_main_karat(running_gold_18k, 18)
                    + convert_to_main_karat(running_gold_21k, 21)
                    + convert_to_main_karat(running_gold_22k, 22)
                    + convert_to_main_karat(running_gold_24k, 24),
                    3,
                ),
            }

            if karat_detail:
                entry_data['running_balance']['by_karat'] = {
                    '18k': round(running_gold_18k, 3),
                    '21k': round(running_gold_21k, 3),
                    '22k': round(running_gold_22k, 3),
                    '24k': round(running_gold_24k, 3),
                }

        entries_payload.append(entry_data)

    summary = {
        'total_entries': len(entries_payload),
        'totals': {
            'cash_debit': round(total_cash_debit, 2),
            'cash_credit': round(total_cash_credit, 2),
            'gold_debit_normalized': round(total_gold_debit_normalized, 3),
            'gold_credit_normalized': round(total_gold_credit_normalized, 3),
        },
        'final_balance': {
            'cash': round(running_cash_balance, 2),
            'gold_normalized': round(
                convert_to_main_karat(running_gold_18k, 18)
                + convert_to_main_karat(running_gold_21k, 21)
                + convert_to_main_karat(running_gold_22k, 22)
                + convert_to_main_karat(running_gold_24k, 24),
                3,
            ),
        },
    }

    if karat_detail:
        summary['final_balance']['by_karat'] = {
            '18k': round(running_gold_18k, 3),
            '21k': round(running_gold_21k, 3),
            '22k': round(running_gold_22k, 3),
            '24k': round(running_gold_24k, 3),
        }

    return jsonify({
        'entries': entries_payload,
        'summary': summary,
        'pagination': {
            'page': page,
            'per_page': per_page,
            'total': total_count,
            'pages': max(1, -(-total_count // per_page)),  # ceiling division
            'has_next': page * per_page < total_count,
            'has_prev': page > 1,
        },
        'filters': {
            'account_id': account_id,
            'start_date': start_date_param,
            'end_date': end_date_param,
            'show_balances': show_balances,
            'karat_detail': karat_detail,
            'posted_only': posted_only,
            'reference_types': reference_filters,
            'created_by': created_by_param,
            'posted_by': posted_by_param,
            'user': user_param,
            'branch': branch_param,
        },
    })

@reports_bp.route('/analytics/summary', methods=['GET'])
@require_permission('reports.financial')
def get_analytics_summary():
    """Financial Dimensions summary (line-level analytics).

    Query Parameters:
    - group_by: branch | gold_office | office | transaction_type | employee
    - start_date: YYYY-MM-DD (optional)
    - end_date: YYYY-MM-DD (optional)
    - posted_only: true|false (default true)
    """
    from models import DimensionDefinition, DimensionValue, DimensionSetItem, JournalEntry, Settings, Account

    group_by = (request.args.get('group_by') or 'branch').strip().lower()
    start_date_param = request.args.get('start_date')
    end_date_param = request.args.get('end_date')
    posted_only = request.args.get('posted_only', 'true').lower() == 'true'

    # Historical: "office" dimension code stores Branch.
    # New: "gold_office" stores مكاتب التسكير.
    code_map = {
        'branch': 'office',
        'office': 'office',
        'gold_office': 'gold_office',
        'transaction_type': 'transaction_type',
        'employee': 'employee',
    }
    dimension_code = code_map.get(group_by, 'office')

    try:
        start_value = _parse_iso_date(start_date_param, 'start_date') if start_date_param else None
        end_value = _parse_iso_date(end_date_param, 'end_date') if end_date_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    start_dt = datetime.combine(start_value, datetime.min.time()) if start_value else None
    end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1) if end_value else None
    if start_dt and end_dt and end_dt <= start_dt:
        end_dt = start_dt + timedelta(days=1)

    label_expr = func.coalesce(
        DimensionValue.label_ar,
        DimensionValue.str_value,
        cast(DimensionValue.int_value, String),
    )

    dim_subq = (
        db.session.query(
            DimensionSetItem.dimension_set_id.label('dimension_set_id'),
            DimensionValue.id.label('dimension_value_id'),
            label_expr.label('label'),
        )
        .join(DimensionValue, DimensionValue.id == DimensionSetItem.dimension_value_id)
        .join(DimensionDefinition, DimensionDefinition.id == DimensionValue.definition_id)
        .filter(DimensionDefinition.code == dimension_code)
        .subquery()
    )

    # Determine main karat for fallback weight normalization
    main_karat = 21
    try:
        settings_row = Settings.query.first()
        if settings_row and settings_row.main_karat:
            main_karat = int(settings_row.main_karat)
    except Exception:
        main_karat = 21

    # Fallback physical 24k-equivalent per line (used when analytic_* is null).
    # نستخدم COALESCE لكل حقل حتى لا تتحول العملية إلى NULL إذا كان أحدهما NULL.
    # 🟡 أولاً نحسب صافي الحركة الوزنية من الحقول الخام لكل العيارات.
    physical_24k_all_expr = (
        (func.coalesce(JournalEntryLine.debit_18k, 0.0) - func.coalesce(JournalEntryLine.credit_18k, 0.0)) * (18.0 / 24.0)
        + (func.coalesce(JournalEntryLine.debit_21k, 0.0) - func.coalesce(JournalEntryLine.credit_21k, 0.0)) * (21.0 / 24.0)
        + (func.coalesce(JournalEntryLine.debit_22k, 0.0) - func.coalesce(JournalEntryLine.credit_22k, 0.0)) * (22.0 / 24.0)
        + (func.coalesce(JournalEntryLine.debit_24k, 0.0) - func.coalesce(JournalEntryLine.credit_24k, 0.0))
    )

    # Inventory accounts only (where weight represents **physical stock**).
    # نركّز هنا على:
    # - حسابات المخزون المالية 13xx (إن وُجدت بها أوزان)
    # - حسابات المخزون الوزنية الفعلية (71300/71310/71320/71330) لكل العيارات
    # ولا نضم باقي حسابات 71xx مثل الصندوق الوزني أو العملاء وزني.
    gold_inventory_weight_accounts = ['71300', '71310', '71320', '71330']
    inv_condition = or_(
        Account.account_number.like('13%'),
        Account.account_number.in_(gold_inventory_weight_accounts),
    )

    # 🟢 اعتبار الأسطر كـ "وزن فعلي" إذا:
    # - وُسمت صراحة كـ PHYSICAL
    # - أو كانت ANALYTICAL لكنها تخص حسابات مخزون حقيقية (7131xx / 13xx)
    is_physical_line = or_(
        JournalEntryLine.weight_type == 'PHYSICAL',
        and_(JournalEntryLine.weight_type == 'ANALYTICAL', inv_condition),
    )

    physical_24k_expr = case(
        (is_physical_line, physical_24k_all_expr),
        else_=0.0,
    )

    physical_main_expr = physical_24k_expr * (24.0 / float(main_karat or 21))

    # صافي الحركة الوزنية في حسابات المخزون فقط (لأسطر PHYSICAL/Inventory)
    net_24k_inventory = physical_24k_expr

    # وزن خارج من المخزون (بيع / صرف / صهر)
    weight_out_24k_expr = case(
        (and_(inv_condition, net_24k_inventory < 0), -net_24k_inventory),
        else_=0.0,
    )

    # وزن داخل إلى المخزون (شراء / استلام / كسر)
    weight_in_24k_expr = case(
        (and_(inv_condition, net_24k_inventory > 0), net_24k_inventory),
        else_=0.0,
    )

    # Cash: prefer analytic_amount_cash for صافي الكاش، لكن نجمع أيضاً الداخل/الخارج
    # من حسابات النقدية والصناديق والبنوك فقط.
    cash_condition = or_(
        Account.account_type.in_(['cash', 'bank_account', 'digital_wallet']),
    )

    raw_cash_debit_sum = func.sum(
        case(
            (cash_condition, func.coalesce(JournalEntryLine.cash_debit, 0.0)),
            else_=0.0,
        )
    )
    raw_cash_credit_sum = func.sum(
        case(
            (cash_condition, func.coalesce(JournalEntryLine.cash_credit, 0.0)),
            else_=0.0,
        )
    )
    fallback_cash_sum = raw_cash_debit_sum - raw_cash_credit_sum

    # صافي التدفق النقدي بحسب التحليل (إن وجد)، أو من الحقول الخام
    amount_cash_sum = func.coalesce(
        func.sum(JournalEntryLine.analytic_amount_cash),
        fallback_cash_sum,
        0.0,
    )

    # إجمالي الكاش الداخل (مدين) والخارج (دائن) بدون طرح، لعرض "المقبوضات" و"المدفوعات".
    cash_in_sum = raw_cash_debit_sum
    cash_out_sum = raw_cash_credit_sum

    # 🟢 إعطاء أولوية لحقول الـ Analytics ولكن فقط لأسطر PHYSICAL
    analytic_weight_24k_physical_sum = func.sum(
        case(
            (is_physical_line, JournalEntryLine.analytic_weight_24k),
            else_=None,
        )
    )

    analytic_weight_main_physical_sum = func.sum(
        case(
            (is_physical_line, JournalEntryLine.analytic_weight_main),
            else_=None,
        )
    )

    weight_24k_sum = func.coalesce(
        analytic_weight_24k_physical_sum,
        func.sum(physical_24k_expr),
        0.0,
    )

    weight_main_sum = func.coalesce(
        analytic_weight_main_physical_sum,
        func.sum(physical_main_expr),
        0.0,
    )

    # تجميع وزن الداخل/الخارج لحسابات المخزون فقط
    weight_out_24k_sum = func.sum(weight_out_24k_expr)
    weight_in_24k_sum = func.sum(weight_in_24k_expr)

    weight_out_main_sum = weight_out_24k_sum * (24.0 / float(main_karat or 21))
    weight_in_main_sum = weight_in_24k_sum * (24.0 / float(main_karat or 21))

    query = (
        db.session.query(
            func.coalesce(dim_subq.c.label, '(غير محدد)').label('group_label'),
            func.count(JournalEntryLine.id).label('line_count'),
            amount_cash_sum.label('amount_cash'),
            cash_in_sum.label('cash_in'),
            cash_out_sum.label('cash_out'),
            weight_24k_sum.label('weight_24k'),
            weight_main_sum.label('weight_main'),
            weight_out_24k_sum.label('weight_out_24k'),
            weight_in_24k_sum.label('weight_in_24k'),
            weight_out_main_sum.label('weight_out_main'),
            weight_in_main_sum.label('weight_in_main'),
        )
        .select_from(JournalEntryLine)
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .join(Account, Account.id == JournalEntryLine.account_id)
        .outerjoin(dim_subq, dim_subq.c.dimension_set_id == JournalEntryLine.dimension_set_id)
        .filter(JournalEntryLine.is_deleted == False)
        .filter(JournalEntry.is_deleted == False)
    )

    if start_dt:
        query = query.filter(JournalEntry.date >= start_dt)
    if end_dt:
        query = query.filter(JournalEntry.date < end_dt)
    if posted_only:
        query = query.filter(JournalEntry.is_posted == True)

    rows = (
        query
        .group_by(func.coalesce(dim_subq.c.label, '(غير محدد)'))
        .order_by((weight_out_24k_sum + weight_in_24k_sum).desc())
        .all()
    )

    payload = []
    for row in rows:
        # عالج تقريب الصفر لتجنب ظهور -0.00 في الواجهة
        amount_cash_value = float(row.amount_cash or 0.0)
        if abs(amount_cash_value) < 0.005:
            amount_cash_value = 0.0

        # 🆕 تصنيف السلوك (transaction_category) مبدئياً عند التجميع حسب نوع العملية
        if dimension_code == 'transaction_type':
            transaction_category = row.group_label
        else:
            transaction_category = None

        payload.append({
            'group': row.group_label,
            'transaction_category': transaction_category,
            'line_count': int(row.line_count or 0),
            'amount_cash': round(amount_cash_value, 2),
            'cash_in': round(float(row.cash_in or 0.0), 2),
            'cash_out': round(float(row.cash_out or 0.0), 2),
            'weight_24k': round(float(row.weight_24k or 0.0), 6),
            'weight_main': round(float(row.weight_main or 0.0), 6),
            'weight_out_24k': round(float(row.weight_out_24k or 0.0), 6),
            'weight_in_24k': round(float(row.weight_in_24k or 0.0), 6),
            'weight_out_main': round(float(row.weight_out_main or 0.0), 6),
            'weight_in_main': round(float(row.weight_in_main or 0.0), 6),
        })

    return jsonify({
        'group_by': dimension_code,
        'items': payload,
        'filters': {
            'start_date': start_date_param,
            'end_date': end_date_param,
            'posted_only': posted_only,
        },
    })

@reports_bp.route('/reports/sales_vs_purchases_trend', methods=['GET'])
@require_permission('reports.sales')
def get_sales_vs_purchases_trend():
    """Sales vs Purchases Trend report (by day/week/month)

    Returns timeline buckets with totals for sales and purchases and basic margins.
    """
    start_date_param = request.args.get('start_date')
    end_date_param = request.args.get('end_date')
    group_interval = (request.args.get('group_interval') or 'day').lower()
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    gold_type = request.args.get('gold_type')

    valid_intervals = {'day', 'week', 'month'}
    if group_interval not in valid_intervals:
        group_interval = 'day'

    try:
        start_dt = None
        end_dt = None

        if start_date_param:
            start_value = _parse_iso_date(start_date_param, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date_param:
            end_value = _parse_iso_date(end_date_param, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    now = datetime.now()
    if end_dt is None:
        end_dt = datetime.combine(now.date(), datetime.min.time()) + timedelta(days=1)
    if start_dt is None:
        start_dt = end_dt - timedelta(days=30)

    if end_dt <= start_dt:
        end_dt = start_dt + timedelta(days=1)

    # Determine invoice direction mapping (reuse logic similar to inventory)
    purchase_types = {'شراء', 'شراء من عميل'}
    sale_types = {'بيع', 'فاتورة بيع', 'sell', 'sale'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء (مورد)'}

    def determine_direction(invoice_type_value: str):
        normalized = (invoice_type_value or '').strip()
        if 'مرتجع' in normalized:
            # treat returns as opposite
            if 'بيع' in normalized:
                return 1
            if 'شراء' in normalized:
                return -1
        if normalized in purchase_types or ('شراء' in normalized and 'مرتجع' not in normalized):
            return 1
        if normalized in sale_types or ('بيع' in normalized and 'مرتجع' not in normalized):
            return -1
        return 0

    def bucket_key_for(date_value):
        if group_interval == 'week':
            return date_value - timedelta(days=date_value.weekday())
        if group_interval == 'month':
            return date_value.replace(day=1)
        return date_value

    def bucket_bounds(start_date_value):
        start_dt_value = datetime.combine(start_date_value, datetime.min.time())
        if group_interval == 'week':
            end_dt_value = start_dt_value + timedelta(days=7)
            label = f"{start_date_value.isocalendar()[0]}-W{start_date_value.isocalendar()[1]:02d}"
        elif group_interval == 'month':
            next_month = (start_date_value.replace(day=28) + timedelta(days=4)).replace(day=1)
            end_dt_value = datetime.combine(next_month, datetime.min.time())
            label = start_date_value.strftime('%Y-%m')
        else:
            end_dt_value = start_dt_value + timedelta(days=1)
            label = start_date_value.isoformat()
        return start_dt_value, end_dt_value, label

    timeline_map = {}

    def ensure_bucket(date_value):
        key = bucket_key_for(date_value)
        if key not in timeline_map:
            start_bound, end_bound, label = bucket_bounds(key)
            timeline_map[key] = {
                'label': label,
                'start': start_bound,
                'end': end_bound,
                'sales_total': 0.0,
                'purchases_total': 0.0,
                'sales_weight': 0.0,
                'purchases_weight': 0.0,
                'sales_count': 0,
                'purchases_count': 0,
                'sales_margin_cash': 0.0,
                'purchases_margin_cash': 0.0,
                'sales_margin_gold': 0.0,
                'purchases_margin_gold': 0.0,
            }
        return timeline_map[key]

    # Query invoices in date range with optional filters
    invoice_query = (
        Invoice.query
        .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
        .options(joinedload(Invoice.karat_lines), joinedload(Invoice.items))
    )
    if gold_type:
        invoice_query = invoice_query.filter(Invoice.gold_type == gold_type)
    if not include_unposted:
        invoice_query = invoice_query.filter(Invoice.is_posted == True)

    invoices = invoice_query.order_by(Invoice.date.asc()).all()

    summary = {
        'sales_total': 0.0,
        'purchases_total': 0.0,
        'sales_weight': 0.0,
        'purchases_weight': 0.0,
        'sales_margin_cash': 0.0,
        'purchases_margin_cash': 0.0,
        'sales_margin_gold': 0.0,
        'purchases_margin_gold': 0.0,
    }

    def safe_float(v):
        try:
            return float(v or 0.0)
        except (TypeError, ValueError):
            return 0.0

    for inv in invoices:
        if not inv.date:
            continue
        direction = determine_direction(inv.invoice_type)
        if direction == 0:
            continue

        # totals — v2: الوزن يُحسب من karat_lines/items بدون ضرب في الكمية
        total_cash = safe_float(inv.total)
        weight = _invoice_weight_mk_v2(inv)

        bucket = ensure_bucket(inv.date.date())
        if direction < 0:
            # sale
            bucket['sales_total'] += total_cash
            bucket['sales_weight'] += weight
            bucket['sales_count'] += 1
            bucket['sales_margin_cash'] += safe_float(inv.profit_cash)
            bucket['sales_margin_gold'] += safe_float(inv.profit_gold)
            summary['sales_total'] += total_cash
            summary['sales_weight'] += weight
            summary['sales_margin_cash'] += safe_float(inv.profit_cash)
            summary['sales_margin_gold'] += safe_float(inv.profit_gold)
        else:
            # purchase
            bucket['purchases_total'] += total_cash
            bucket['purchases_weight'] += weight
            bucket['purchases_count'] += 1
            bucket['purchases_margin_cash'] += safe_float(inv.profit_cash)
            bucket['purchases_margin_gold'] += safe_float(inv.profit_gold)
            summary['purchases_total'] += total_cash
            summary['purchases_weight'] += weight
            summary['purchases_margin_cash'] += safe_float(inv.profit_cash)
            summary['purchases_margin_gold'] += safe_float(inv.profit_gold)

    def round_money(v):
        return round(float(v or 0.0), 2)

    def round_weight(v):
        return round(float(v or 0.0), 3)

    timeline_payload = []
    for key in sorted(timeline_map.keys()):
        b = timeline_map[key]
        timeline_payload.append({
            'label': b['label'],
            'start': b['start'].isoformat(),
            'end': b['end'].isoformat(),
            'sales_total': round_money(b['sales_total']),
            'purchases_total': round_money(b['purchases_total']),
            'net_total': round_money(b['sales_total'] - b['purchases_total']),
            'sales_weight': round_weight(b['sales_weight']),
            'purchases_weight': round_weight(b['purchases_weight']),
            'net_weight': round_weight(b['sales_weight'] - b['purchases_weight']),
            'sales_count': b['sales_count'],
            'purchases_count': b['purchases_count'],
            'sales_margin_cash': round_money(b['sales_margin_cash']),
            'purchases_margin_cash': round_money(b['purchases_margin_cash']),
            'sales_margin_gold': round_weight(b['sales_margin_gold']),
            'purchases_margin_gold': round_weight(b['purchases_margin_gold']),
        })

    summary_payload = {
        'sales_total': round_money(summary['sales_total']),
        'purchases_total': round_money(summary['purchases_total']),
        'net_total': round_money(summary['sales_total'] - summary['purchases_total']),
        'sales_weight': round_weight(summary['sales_weight']),
        'purchases_weight': round_weight(summary['purchases_weight']),
        'net_weight': round_weight(summary['sales_weight'] - summary['purchases_weight']),
        'sales_margin_cash': round_money(summary['sales_margin_cash']),
        'purchases_margin_cash': round_money(summary['purchases_margin_cash']),
        'sales_margin_gold': round_weight(summary['sales_margin_gold']),
        'purchases_margin_gold': round_weight(summary['purchases_margin_gold']),
    }

    return jsonify({
        'summary': summary_payload,
        'timeline': timeline_payload,
        'filters': {
            'start_date': start_dt.date().isoformat(),
            'end_date': (end_dt - timedelta(seconds=1)).date().isoformat(),
            'group_interval': group_interval,
            'include_unposted': include_unposted,
            'gold_type': gold_type,
        },
        'count': len(timeline_payload),
    })

@reports_bp.route('/reports/customer_balances_aging', methods=['GET'])
@require_permission('reports.customers')
def get_customer_balances_aging():
    """Aging analysis for customer balances (cash + gold)."""

    cutoff_param = request.args.get('cutoff_date')
    include_zero_balances = request.args.get('include_zero_balances', 'false').lower() == 'true'
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    group_param = request.args.get('customer_group_id') or request.args.get('account_category_id')
    top_limit_param = request.args.get('top_limit')

    try:
        cutoff_value = _parse_iso_date(cutoff_param, 'cutoff_date') if cutoff_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    cutoff_date = cutoff_value or datetime.now().date()
    cutoff_end = datetime.combine(cutoff_date, datetime.min.time()) + timedelta(days=1)

    try:
        top_limit = int(top_limit_param) if top_limit_param else 5
    except ValueError:
        return jsonify({'error': 'Invalid top_limit parameter'}), 400
    top_limit = max(3, min(top_limit, 25))

    customer_group_id = None
    if group_param not in (None, ''):
        try:
            customer_group_id = int(group_param)
        except ValueError:
            return jsonify({'error': 'customer_group_id must be numeric'}), 400

    invoice_query = (
        Invoice.query.options(
            joinedload(Invoice.customer).joinedload(Customer.account_category)
        )
        .filter(Invoice.customer_id.isnot(None))
        .filter(Invoice.date < cutoff_end)
    )

    if not include_unposted:
        invoice_query = invoice_query.filter(Invoice.is_posted == True)

    if customer_group_id is not None:
        invoice_query = invoice_query.join(Customer, Customer.id == Invoice.customer_id)
        invoice_query = invoice_query.filter(Customer.account_category_id == customer_group_id)

    invoices = invoice_query.all()

    invoice_ids = [invoice.id for invoice in invoices]
    payments_map = {}
    if invoice_ids:
        payment_rows = (
            db.session.query(
                InvoicePayment.invoice_id,
                func.coalesce(func.sum(InvoicePayment.amount), 0.0).label('total_payments'),
            )
            .filter(InvoicePayment.invoice_id.in_(invoice_ids))
            .group_by(InvoicePayment.invoice_id)
            .all()
        )
        payments_map = {row.invoice_id: float(row.total_payments or 0.0) for row in payment_rows}

    bucket_keys = ['current', 'days_31_60', 'days_61_90', 'over_90']
    bucket_labels = {
        'current': {'ar': 'حالي (0-30)', 'en': 'Current (0-30)'},
        'days_31_60': {'ar': 'متأخر 31-60 يوم', 'en': 'Past Due 31-60'},
        'days_61_90': {'ar': 'متأخر 61-90 يوم', 'en': 'Past Due 61-90'},
        'over_90': {'ar': 'أكثر من 90 يوم', 'en': 'Over 90'},
    }

    def classify_bucket(days_overdue: int) -> str:
        if days_overdue <= 30:
            return 'current'
        if days_overdue <= 60:
            return 'days_31_60'
        if days_overdue <= 90:
            return 'days_61_90'
        return 'over_90'

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    customer_entries = {}
    summary_bucket_cash = {key: 0.0 for key in bucket_keys}
    summary_bucket_weight = {key: 0.0 for key in bucket_keys}
    summary_credit_cash = 0.0
    summary_credit_weight = 0.0

    def ensure_customer_entry(customer_obj):
        entry = customer_entries.get(customer_obj.id)
        if entry is None:
            entry = {
                'customer_id': customer_obj.id,
                'customer_code': customer_obj.customer_code,
                'customer_name': customer_obj.name,
                'account_category_id': customer_obj.account_category_id,
                'account_category_name': customer_obj.account_category.name if customer_obj.account_category else None,
                'buckets': {
                    key: {'cash': 0.0, 'weight': 0.0, 'invoice_count': 0}
                    for key in bucket_keys
                },
                'outstanding_cash': 0.0,
                'outstanding_weight': 0.0,
                'credit_cash': 0.0,
                'credit_weight': 0.0,
                'invoice_count': 0,
                'open_invoice_count': 0,
                'last_invoice_date': None,
                'oldest_invoice_date': None,
                'total_days_overdue': 0.0,
                'due_invoices_count': 0,
                'recent_invoices': [],
            }
            customer_entries[customer_obj.id] = entry
        return entry

    def normalize_direction(invoice_type_value: str) -> int:
        normalized = (invoice_type_value or '').strip()
        if 'مرتجع' in normalized and 'بيع' in normalized:
            return -1
        if 'بيع' in normalized:
            return 1
        if normalized == 'فاتورة بيع':
            return 1
        return 0

    for invoice in invoices:
        direction = normalize_direction(invoice.invoice_type)
        if direction == 0:
            continue

        customer_obj = invoice.customer
        if not customer_obj:
            continue

        entry = ensure_customer_entry(customer_obj)
        entry['invoice_count'] += 1

        invoice_date = invoice.date.date() if invoice.date else cutoff_date
        if entry['last_invoice_date'] is None or invoice_date > entry['last_invoice_date']:
            entry['last_invoice_date'] = invoice_date
        if entry['oldest_invoice_date'] is None or invoice_date < entry['oldest_invoice_date']:
            entry['oldest_invoice_date'] = invoice_date

        invoice_total_cash = invoice.net_amount if invoice.net_amount is not None else invoice.total or 0.0
        paid_amount = invoice.amount_paid if invoice.amount_paid is not None else payments_map.get(invoice.id, 0.0)
        open_cash = (invoice_total_cash - paid_amount) * direction

        total_weight = invoice.total_weight or 0.0
        settled_weight = invoice.settled_gold_weight or invoice.payment_gold_weight or 0.0
        open_weight = (total_weight - settled_weight) * direction

        cash_positive = open_cash > 0.0005
        weight_positive = open_weight > 0.0005

        negative_cash = abs(open_cash) if open_cash < -0.0005 else 0.0
        negative_weight = abs(open_weight) if open_weight < -0.0005 else 0.0
        if negative_cash:
            summary_credit_cash += negative_cash
            if include_zero_balances:
                entry['credit_cash'] += round_money(negative_cash)
        if negative_weight:
            summary_credit_weight += negative_weight
            if include_zero_balances:
                entry['credit_weight'] += round_weight(negative_weight)

        if not (cash_positive or weight_positive):
            continue

        days_overdue = max(0, (cutoff_date - invoice_date).days)
        bucket_key = classify_bucket(days_overdue)
        bucket_data = entry['buckets'][bucket_key]
        bucket_added = False

        if cash_positive:
            value = round_money(open_cash)
            bucket_data['cash'] += value
            entry['outstanding_cash'] += value
            summary_bucket_cash[bucket_key] += value
            entry['total_days_overdue'] += days_overdue
            entry['due_invoices_count'] += 1
            bucket_added = True

        if weight_positive:
            weight_value = round_weight(open_weight)
            bucket_data['weight'] += weight_value
            entry['outstanding_weight'] += weight_value
            summary_bucket_weight[bucket_key] += weight_value
            bucket_added = True

        if bucket_added:
            bucket_data['invoice_count'] += 1
            entry['open_invoice_count'] += 1
            if len(entry['recent_invoices']) < 5:
                entry['recent_invoices'].append({
                    'invoice_id': invoice.id,
                    'invoice_number': invoice.invoice_type_id,
                    'date': invoice.date.isoformat() if invoice.date else None,
                    'days_overdue': days_overdue,
                    'open_cash': round_money(open_cash) if cash_positive else 0.0,
                    'open_weight': round_weight(open_weight) if weight_positive else 0.0,
                })

    customers_payload = []
    for entry in customer_entries.values():
        outstanding_cash = round_money(entry['outstanding_cash'])
        outstanding_weight = round_weight(entry['outstanding_weight'])
        if not include_zero_balances and outstanding_cash <= 0.0 and outstanding_weight <= 0.0:
            continue

        avg_days = 0.0
        if entry['due_invoices_count'] > 0:
            avg_days = round(entry['total_days_overdue'] / entry['due_invoices_count'], 1)

        customers_payload.append({
            'customer_id': entry['customer_id'],
            'customer_code': entry['customer_code'],
            'customer_name': entry['customer_name'],
            'account_category_id': entry['account_category_id'],
            'account_category_name': entry['account_category_name'],
            'outstanding_cash': outstanding_cash,
            'outstanding_weight': outstanding_weight,
            'credit_cash': round_money(entry['credit_cash']),
            'credit_weight': round_weight(entry['credit_weight']),
            'average_days_overdue': avg_days,
            'last_invoice_date': entry['last_invoice_date'].isoformat() if entry['last_invoice_date'] else None,
            'oldest_invoice_date': entry['oldest_invoice_date'].isoformat() if entry['oldest_invoice_date'] else None,
            'invoice_count': entry['invoice_count'],
            'open_invoice_count': entry['open_invoice_count'],
            'buckets': {
                key: {
                    'cash': round_money(entry['buckets'][key]['cash']),
                    'weight': round_weight(entry['buckets'][key]['weight'])
                }
                for key in bucket_keys
            },
            'recent_invoices': entry['recent_invoices'],
        })

    customers_payload.sort(key=lambda item: (item['outstanding_cash'], item['outstanding_weight']), reverse=True)

    def overdue_score(item):
        over_90_cash = item['buckets']['over_90']['cash']
        if over_90_cash and over_90_cash > 0:
            return over_90_cash
        return item['outstanding_cash'] * 0.1

    top_overdue_customers = sorted(customers_payload, key=overdue_score, reverse=True)[:top_limit]

    summary = {
        'total_customers': len(customers_payload),
        'total_outstanding_cash': round_money(sum(summary_bucket_cash.values())),
        'total_outstanding_weight': round_weight(sum(summary_bucket_weight.values())),
        'bucket_cash': {key: round_money(value) for key, value in summary_bucket_cash.items()},
        'bucket_weight': {key: round_weight(value) for key, value in summary_bucket_weight.items()},
        'credit_balances_cash': round_money(summary_credit_cash),
        'credit_balances_weight': round_weight(summary_credit_weight),
    }

    return jsonify({
        'summary': summary,
        'customers': customers_payload,
        'top_overdue_customers': top_overdue_customers,
        'buckets': bucket_labels,
        'filters': {
            'cutoff_date': cutoff_date.isoformat(),
            'include_zero_balances': include_zero_balances,
            'include_unposted': include_unposted,
            'customer_group_id': customer_group_id,
            'top_limit': top_limit,
        },
        'count': len(customers_payload),
    })
    
    # Build query
    query = JournalEntryLine.query.join(JournalEntry).filter(JournalEntryLine.is_deleted == False)
    
    # Apply filters
    if account_id:
        query = query.filter(JournalEntryLine.account_id == account_id)
    
    if start_date:
        from datetime import datetime
        start_dt = datetime.strptime(start_date, '%Y-%m-%d')
        query = query.filter(JournalEntry.date >= start_dt)
    
    if end_date:
        from datetime import datetime
        end_dt = datetime.strptime(end_date, '%Y-%m-%d')
        query = query.filter(JournalEntry.date <= end_dt)
    
    # Order by date and id
    lines = query.order_by(JournalEntry.date.asc(), JournalEntry.id.asc()).all()
    
    # Calculate running balances
    running_cash_balance = 0
    running_gold_18k = 0
    running_gold_21k = 0
    running_gold_22k = 0
    running_gold_24k = 0
    
    result = []
    for line in lines:
        # Calculate normalized gold for main view
        gold_debit_normalized = (
            convert_to_main_karat(line.debit_18k or 0, 18) +
            convert_to_main_karat(line.debit_21k or 0, 21) +
            convert_to_main_karat(line.debit_22k or 0, 22) +
            convert_to_main_karat(line.debit_24k or 0, 24)
        )
        gold_credit_normalized = (
            convert_to_main_karat(line.credit_18k or 0, 18) +
            convert_to_main_karat(line.credit_21k or 0, 21) +
            convert_to_main_karat(line.credit_22k or 0, 22) +
            convert_to_main_karat(line.credit_24k or 0, 24)
        )
        
        # Update running balances
        running_cash_balance += (line.cash_debit or 0) - (line.cash_credit or 0)
        running_gold_18k += (line.debit_18k or 0) - (line.credit_18k or 0)
        running_gold_21k += (line.debit_21k or 0) - (line.credit_21k or 0)
        running_gold_22k += (line.debit_22k or 0) - (line.credit_22k or 0)
        running_gold_24k += (line.debit_24k or 0) - (line.credit_24k or 0)
        
        entry_data = {
            'id': line.id,
            'journal_entry_id': line.journal_entry.id,
            'date': line.journal_entry.date.isoformat(),
            'type': 'Journal Entry',
            'description': line.journal_entry.description or line.description,
            'account_id': line.account_id,
            'account_name': line.account.name if line.account else 'Unknown Account',
            'account_number': line.account.account_number if line.account else 'N/A',
            'cash_debit': round(line.cash_debit or 0, 2),
            'cash_credit': round(line.cash_credit or 0, 2),
            'gold_debit': round(gold_debit_normalized, 3),
            'gold_credit': round(gold_credit_normalized, 3),
        }
        
        # Add karat details if requested
        if karat_detail:
            entry_data['karat_details'] = {
                '18k': {
                    'debit': round(line.debit_18k or 0, 3),
                    'credit': round(line.credit_18k or 0, 3)
                },
                '21k': {
                    'debit': round(line.debit_21k or 0, 3),
                    'credit': round(line.credit_21k or 0, 3)
                },
                '22k': {
                    'debit': round(line.debit_22k or 0, 3),
                    'credit': round(line.credit_22k or 0, 3)
                },
                '24k': {
                    'debit': round(line.debit_24k or 0, 3),
                    'credit': round(line.credit_24k or 0, 3)
                }
            }
        
        # Add running balances if requested
        if show_balances:
            entry_data['running_balance'] = {
                'cash': round(running_cash_balance, 2),
                'gold_normalized': round(
                    convert_to_main_karat(running_gold_18k, 18) +
                    convert_to_main_karat(running_gold_21k, 21) +
                    convert_to_main_karat(running_gold_22k, 22) +
                    convert_to_main_karat(running_gold_24k, 24),
                    3
                )
            }
            
            if karat_detail:
                entry_data['running_balance']['by_karat'] = {
                    '18k': round(running_gold_18k, 3),
                    '21k': round(running_gold_21k, 3),
                    '22k': round(running_gold_22k, 3),
                    '24k': round(running_gold_24k, 3)
                }
        
        result.append(entry_data)
    
    # Summary
    summary = {
        'total_entries': len(result),
        'final_balance': {
            'cash': round(running_cash_balance, 2),
            'gold_normalized': round(
                convert_to_main_karat(running_gold_18k, 18) +
                convert_to_main_karat(running_gold_21k, 21) +
                convert_to_main_karat(running_gold_22k, 22) +
                convert_to_main_karat(running_gold_24k, 24),
                3
            )
        }
    }
    
    if karat_detail:
        summary['final_balance']['by_karat'] = {
            '18k': round(running_gold_18k, 3),
            '21k': round(running_gold_21k, 3),
            '22k': round(running_gold_22k, 3),
            '24k': round(running_gold_24k, 3)
        }
    
    return jsonify({
        'entries': result,
        'summary': summary,
        'filters': {
            'account_id': account_id,
            'start_date': start_date,
            'end_date': end_date,
            'show_balances': show_balances,
            'karat_detail': karat_detail
        }
    })

# Accounts domain → routes/accounts.py (ledger)
# (GET /account_ledger/<id>)

@reports_bp.route('/trial_balance', methods=['GET'])
@require_permission('reports.financial')
def get_trial_balance():
    """
    Enhanced Trial Balance with date filtering and karat detail support
    Query Parameters:
    - start_date: Filter entries from this date (YYYY-MM-DD)
    - end_date: Filter entries to this date (YYYY-MM-DD)
    - karat_detail: If true, return karat breakdown; if false, return normalized totals
    """
    # Get optional query parameters
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    karat_detail = request.args.get('karat_detail', 'false').lower() == 'true'
    
    # Start building the query
    query = db.session.query(
        Account.id,
        Account.name,
        Account.account_number,
        func.sum(JournalEntryLine.cash_debit).label('total_cash_debit'),
        func.sum(JournalEntryLine.cash_credit).label('total_cash_credit'),
        func.sum(JournalEntryLine.debit_18k).label('total_debit_18k'),
        func.sum(JournalEntryLine.credit_18k).label('total_credit_18k'),
        func.sum(JournalEntryLine.debit_21k).label('total_debit_21k'),
        func.sum(JournalEntryLine.credit_21k).label('total_credit_21k'),
        func.sum(JournalEntryLine.debit_22k).label('total_debit_22k'),
        func.sum(JournalEntryLine.credit_22k).label('total_credit_22k'),
        func.sum(JournalEntryLine.debit_24k).label('total_debit_24k'),
        func.sum(JournalEntryLine.credit_24k).label('total_credit_24k')
    ).join(Account).join(JournalEntry)

    # Always restrict to posted, non-deleted, non-draft entries — the same
    # set that _rebuild_all_account_balances() uses.  Without is_draft=False
    # the endpoint includes "posted-but-still-draft" JEs whose lines are
    # unbalanced, causing Dr-Cr to diverge from stored Account.balance_*
    # values (116,378 divergence observed in production July 2026).
    je_filters = [
        JournalEntry.is_posted == True,
        func.coalesce(JournalEntry.is_deleted, False) == False,
        func.coalesce(JournalEntryLine.is_deleted, False) == False,
    ]
    if _db_has_column('journal_entry', 'is_draft'):
        je_filters.append(JournalEntry.is_draft == False)
    query = query.filter(*je_filters)

    # Apply date filters if provided
    if start_date:
        try:
            start_dt = datetime.strptime(start_date, '%Y-%m-%d')
            query = query.filter(JournalEntry.entry_date >= start_dt)
        except ValueError:
            return jsonify({'error': 'Invalid start_date format. Use YYYY-MM-DD'}), 400
    
    if end_date:
        try:
            end_dt = datetime.strptime(end_date, '%Y-%m-%d')
            query = query.filter(JournalEntry.entry_date <= end_dt)
        except ValueError:
            return jsonify({'error': 'Invalid end_date format. Use YYYY-MM-DD'}), 400
    
    query_result = query.group_by(Account.id, Account.name, Account.account_number).all()

    trial_balance = []
    
    # Initialize grand totals
    if karat_detail:
        totals = {
            'cash_debit': 0, 'cash_credit': 0,
            'debit_18k': 0, 'credit_18k': 0,
            'debit_21k': 0, 'credit_21k': 0,
            'debit_22k': 0, 'credit_22k': 0,
            'debit_24k': 0, 'credit_24k': 0,
        }
    else:
        totals = {
            'gold_debit': 0, 'gold_credit': 0,
            'cash_debit': 0, 'cash_credit': 0,
        }

    for row in query_result:
        cash_debit = row.total_cash_debit or 0
        cash_credit = row.total_cash_credit or 0
        
        if karat_detail:
            # Return karat breakdown
            debit_18k = row.total_debit_18k or 0
            credit_18k = row.total_credit_18k or 0
            debit_21k = row.total_debit_21k or 0
            credit_21k = row.total_credit_21k or 0
            debit_22k = row.total_debit_22k or 0
            credit_22k = row.total_credit_22k or 0
            debit_24k = row.total_debit_24k or 0
            credit_24k = row.total_credit_24k or 0
            
            # Only add accounts that have transactions
            if any([cash_debit, cash_credit, debit_18k, credit_18k, debit_21k, credit_21k, 
                    debit_22k, credit_22k, debit_24k, credit_24k]):
                
                # Calculate balances for each karat
                balance_18k = debit_18k - credit_18k
                balance_21k = debit_21k - credit_21k
                balance_22k = debit_22k - credit_22k
                balance_24k = debit_24k - credit_24k
                cash_balance = cash_debit - cash_credit
                
                trial_balance.append({
                    'account_id': row.id,
                    'account_number': row.account_number,
                    'account_name': row.name,
                    'cash_debit': cash_debit,
                    'cash_credit': cash_credit,
                    'cash_balance': cash_balance,
                    'debit_18k': debit_18k,
                    'credit_18k': credit_18k,
                    'balance_18k': balance_18k,
                    'debit_21k': debit_21k,
                    'credit_21k': credit_21k,
                    'balance_21k': balance_21k,
                    'debit_22k': debit_22k,
                    'credit_22k': credit_22k,
                    'balance_22k': balance_22k,
                    'debit_24k': debit_24k,
                    'credit_24k': credit_24k,
                    'balance_24k': balance_24k,
                })
                
                # Update totals
                totals['cash_debit'] += cash_debit
                totals['cash_credit'] += cash_credit
                totals['debit_18k'] += debit_18k
                totals['credit_18k'] += credit_18k
                totals['debit_21k'] += debit_21k
                totals['credit_21k'] += credit_21k
                totals['debit_22k'] += debit_22k
                totals['credit_22k'] += credit_22k
                totals['debit_24k'] += debit_24k
                totals['credit_24k'] += credit_24k
        else:
            # Normalize gold weights to main karat
            gold_debit = (
                convert_to_main_karat(row.total_debit_18k or 0, 18) +
                convert_to_main_karat(row.total_debit_21k or 0, 21) +
                convert_to_main_karat(row.total_debit_22k or 0, 22) +
                convert_to_main_karat(row.total_debit_24k or 0, 24)
            )
            gold_credit = (
                convert_to_main_karat(row.total_credit_18k or 0, 18) +
                convert_to_main_karat(row.total_credit_21k or 0, 21) +
                convert_to_main_karat(row.total_credit_22k or 0, 22) +
                convert_to_main_karat(row.total_credit_24k or 0, 24)
            )
            
            # Only add accounts that have transactions
            if gold_debit != 0 or gold_credit != 0 or cash_debit != 0 or cash_credit != 0:
                gold_balance = gold_debit - gold_credit
                cash_balance = cash_debit - cash_credit
                
                trial_balance.append({
                    'account_id': row.id,
                    'account_number': row.account_number,
                    'account_name': row.name,
                    'gold_debit': gold_debit,
                    'gold_credit': gold_credit,
                    'gold_balance': gold_balance,
                    'cash_debit': cash_debit,
                    'cash_credit': cash_credit,
                    'cash_balance': cash_balance,
                })
                
                totals['gold_debit'] += gold_debit
                totals['gold_credit'] += gold_credit
                totals['cash_debit'] += cash_debit
                totals['cash_credit'] += cash_credit

    # Calculate total balances
    if karat_detail:
        totals['cash_balance'] = totals['cash_debit'] - totals['cash_credit']
        totals['balance_18k'] = totals['debit_18k'] - totals['credit_18k']
        totals['balance_21k'] = totals['debit_21k'] - totals['credit_21k']
        totals['balance_22k'] = totals['debit_22k'] - totals['credit_22k']
        totals['balance_24k'] = totals['debit_24k'] - totals['credit_24k']
    else:
        totals['gold_balance'] = totals['gold_debit'] - totals['gold_credit']
        totals['cash_balance'] = totals['cash_debit'] - totals['cash_credit']

    return jsonify({
        'trial_balance': trial_balance,
        'totals': totals,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'karat_detail': karat_detail,
        },
        'count': len(trial_balance),
    })

@reports_bp.route('/reports/gold_price_history', methods=['GET'])
@require_permission('reports.financial')
def get_gold_price_history_report():
    """تحليل تاريخي لأسعار الذهب (أونصة دولار → جرام بالريال والعيار الرئيسي)."""

    group_interval = (request.args.get('group_interval') or 'day').lower()
    if group_interval not in {'day', 'week', 'month'}:
        group_interval = 'day'

    start_param = request.args.get('start_date')
    end_param = request.args.get('end_date')
    limit_param = request.args.get('limit')

    try:
        start_value = _parse_iso_date(start_param, 'start_date') if start_param else None
        end_value = _parse_iso_date(end_param, 'end_date') if end_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    now = datetime.now()
    default_start = (now - timedelta(days=90)).date()
    applied_start = start_value or default_start
    applied_end = end_value or now.date()

    if applied_start > applied_end:
        return jsonify({'error': 'start_date must be before end_date'}), 400

    try:
        limit = int(limit_param) if limit_param else 180
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400
    limit = max(12, min(limit, 730))

    start_dt = datetime.combine(applied_start, datetime.min.time())
    end_dt = datetime.combine(applied_end, datetime.min.time()) + timedelta(days=1)

    price_rows = (
        GoldPrice.query
        .filter(GoldPrice.date >= start_dt)
        .filter(GoldPrice.date < end_dt)
        .order_by(GoldPrice.date.asc())
        .all()
    )

    usd_to_sar_factor = SAR_USD_PEG / TROY_OZ_TO_GRAMS

    def usd_oz_to_sar_gram(value):
        if value in (None, 0):
            return 0.0 if value == 0 else None
        return value * usd_to_sar_factor

    def round_money(value, digits=2):
        if value is None:
            return None
        return round(float(value), digits)

    def bucket_key(dt_value: datetime):
        if group_interval == 'month':
            return dt_value.strftime('%Y-%m')
        if group_interval == 'week':
            iso_year, iso_week, _ = dt_value.isocalendar()
            return f'{iso_year}-W{iso_week:02d}'
        return dt_value.strftime('%Y-%m-%d')

    def bucket_label(dt_value: datetime):
        if group_interval == 'month':
            return dt_value.strftime('%b %Y')
        if group_interval == 'week':
            iso_year, iso_week, _ = dt_value.isocalendar()
            return f'الأسبوع {iso_week:02d} - {iso_year}'
        return dt_value.strftime('%d %b %Y')

    bucket_map = {}
    price_points = []

    for row in price_rows:
        timestamp = row.date or now
        price_value = float(row.price or 0.0)
        key = bucket_key(timestamp)
        bucket = bucket_map.get(key)
        if bucket is None:
            bucket = {
                'key': key,
                'label': bucket_label(timestamp),
                'count': 0,
                'total_price': 0.0,
                'min_price': None,
                'max_price': None,
                'first_price': None,
                'last_price': None,
                'first_date': None,
                'last_date': None,
            }
            bucket_map[key] = bucket

        bucket['count'] += 1
        bucket['total_price'] += price_value
        bucket['min_price'] = price_value if bucket['min_price'] is None else min(bucket['min_price'], price_value)
        bucket['max_price'] = price_value if bucket['max_price'] is None else max(bucket['max_price'], price_value)
        if bucket['first_price'] is None:
            bucket['first_price'] = price_value
            bucket['first_date'] = timestamp
        bucket['last_price'] = price_value
        bucket['last_date'] = timestamp

        price_points.append({'bucket': key, 'price_usd': price_value, 'timestamp': timestamp})

    if not price_points:
        return jsonify({
            'summary': {
                'records_considered': 0,
                'buckets_count': 0,
                'average_price_usd': 0.0,
                'average_price_sar_24k': 0.0,
                'average_price_sar_main_karat': 0.0,
                'percent_change': 0.0,
                'volatility_percent': 0.0,
            },
            'series': [],
            'latest_price': None,
            'filters': {
                'start_date': applied_start.isoformat(),
                'end_date': applied_end.isoformat(),
                'group_interval': group_interval,
                'limit': limit,
            },
        })

    keys_in_order = list(bucket_map.keys())
    if len(keys_in_order) > limit:
        keys_to_keep = keys_in_order[-limit:]
        trimmed = {}
        for key in keys_to_keep:
            trimmed[key] = bucket_map[key]
        bucket_map = trimmed
        keep_set = set(keys_to_keep)
        price_points = [point for point in price_points if point['bucket'] in keep_set]

    series_payload = []
    main_karat = get_main_karat() or 21
    main_ratio = main_karat / 24.0

    for bucket in bucket_map.values():
        avg_price = bucket['total_price'] / bucket['count'] if bucket['count'] else 0.0
        avg_sar_24 = usd_oz_to_sar_gram(avg_price)
        high_sar = usd_oz_to_sar_gram(bucket['max_price']) if bucket['max_price'] is not None else None
        low_sar = usd_oz_to_sar_gram(bucket['min_price']) if bucket['min_price'] is not None else None
        change_percent = None
        if bucket['first_price'] and bucket['first_price'] != 0:
            change_percent = ((bucket['last_price'] - bucket['first_price']) / bucket['first_price']) * 100

        trend = 'flat'
        if change_percent is not None:
            if change_percent > 0.2:
                trend = 'up'
            elif change_percent < -0.2:
                trend = 'down'

        series_payload.append({
            'period': bucket['key'],
            'label': bucket['label'],
            'points': bucket['count'],
            'avg_price_usd': round_money(avg_price),
            'avg_price_sar_24k': round_money(avg_sar_24),
            'avg_price_sar_main_karat': round_money(avg_sar_24 * main_ratio if avg_sar_24 is not None else None),
            'high_price_usd': round_money(bucket['max_price']),
            'low_price_usd': round_money(bucket['min_price']),
            'high_price_sar_24k': round_money(high_sar),
            'low_price_sar_24k': round_money(low_sar),
            'first_timestamp': bucket['first_date'].isoformat() if bucket['first_date'] else None,
            'last_timestamp': bucket['last_date'].isoformat() if bucket['last_date'] else None,
            'change_percent': round_money(change_percent),
            'trend': trend,
        })

    price_series = sorted(price_points, key=lambda entry: entry['timestamp'])
    start_point = price_series[0]
    end_point = price_series[-1]
    highest_point = max(price_series, key=lambda entry: entry['price_usd'])
    lowest_point = min(price_series, key=lambda entry: entry['price_usd'])

    prices_list = [entry['price_usd'] for entry in price_series]
    avg_price_usd = sum(prices_list) / len(prices_list)
    avg_price_sar_24 = usd_oz_to_sar_gram(avg_price_usd)
    percent_change = None
    if start_point['price_usd']:
        percent_change = ((end_point['price_usd'] - start_point['price_usd']) / start_point['price_usd']) * 100

    volatility_percent = None
    if len(prices_list) > 1 and avg_price_usd:
        volatility_percent = (pstdev(prices_list) / avg_price_usd) * 100

    summary = {
        'records_considered': len(price_series),
        'buckets_count': len(series_payload),
        'start_price_usd': round_money(start_point['price_usd']),
        'end_price_usd': round_money(end_point['price_usd']),
        'start_price_sar_24k': round_money(usd_oz_to_sar_gram(start_point['price_usd'])),
        'end_price_sar_24k': round_money(usd_oz_to_sar_gram(end_point['price_usd'])),
        'average_price_usd': round_money(avg_price_usd),
        'average_price_sar_24k': round_money(avg_price_sar_24),
        'average_price_sar_main_karat': round_money(avg_price_sar_24 * main_ratio if avg_price_sar_24 is not None else None),
        'absolute_change_usd': round_money(end_point['price_usd'] - start_point['price_usd']),
        'absolute_change_sar_24k': round_money(
            usd_oz_to_sar_gram(end_point['price_usd']) - usd_oz_to_sar_gram(start_point['price_usd'])
        ),
        'percent_change': round_money(percent_change),
        'volatility_percent': round_money(volatility_percent),
        'highest_price': {
            'value_usd': round_money(highest_point['price_usd']),
            'value_sar_24k': round_money(usd_oz_to_sar_gram(highest_point['price_usd'])),
            'timestamp': highest_point['timestamp'].isoformat(),
        },
        'lowest_price': {
            'value_usd': round_money(lowest_point['price_usd']),
            'value_sar_24k': round_money(usd_oz_to_sar_gram(lowest_point['price_usd'])),
            'timestamp': lowest_point['timestamp'].isoformat(),
        },
        'main_karat': main_karat,
    }

    latest_price = {
        'price_usd': round_money(end_point['price_usd']),
        'price_sar_24k': round_money(usd_oz_to_sar_gram(end_point['price_usd'])),
        'price_sar_main_karat': round_money(usd_oz_to_sar_gram(end_point['price_usd']) * main_ratio),
        'timestamp': end_point['timestamp'].isoformat(),
    }

    return jsonify({
        'summary': summary,
        'series': series_payload,
        'latest_price': latest_price,
        'filters': {
            'start_date': applied_start.isoformat(),
            'end_date': applied_end.isoformat(),
            'group_interval': group_interval,
            'limit': limit,
        },
    })

@reports_bp.route('/reports/gold_position', methods=['GET'])
@require_permission('reports.gold_position')
def get_gold_position_report():
    """عرض مركز الذهب الإجمالي حسب الحسابات والخزائن والمكاتب مع تحويل للعيار الرئيسي."""

    include_zero = request.args.get('include_zero', 'false').lower() == 'true'
    min_variance_param = request.args.get('min_variance')
    safe_types_param = request.args.get('safe_types')
    office_ids_param = request.args.get('office_ids')
    karats_param = request.args.get('karats')

    try:
        min_variance = float(min_variance_param) if min_variance_param else 0.05
        min_variance = max(0.0, min(min_variance, 1000.0))
    except ValueError:
        return jsonify({'error': 'Invalid min_variance value'}), 400

    def parse_float(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    def round_weight(value):
        return round(float(value or 0.0), 3)

    main_karat = get_main_karat() or 21

    def normalize_to_main(weight_value, karat_value):
        value = parse_float(weight_value)
        karat = parse_float(karat_value, main_karat)
        if value == 0 or main_karat == 0:
            return 0.0
        return (value * karat) / float(main_karat)

    karat_profiles = [
        {'label': '18k', 'field': 'balance_18k', 'karat': 18},
        {'label': '21k', 'field': 'balance_21k', 'karat': 21},
        {'label': '22k', 'field': 'balance_22k', 'karat': 22},
        {'label': '24k', 'field': 'balance_24k', 'karat': 24},
    ]

    karat_filter = set()
    if karats_param:
        for piece in karats_param.split(','):
            piece = piece.strip().lower().replace('k', '').replace('عيار', '')
            if not piece:
                continue
            try:
                karat_filter.add(float(piece))
            except ValueError:
                return jsonify({'error': f'Invalid karat value: {piece}'}), 400

    safe_types_filter = set()
    if safe_types_param:
        safe_types_filter = {
            token.strip().lower()
            for token in safe_types_param.split(',')
            if token.strip()
        }

    office_ids_filter = set()
    if office_ids_param:
        for piece in office_ids_param.split(','):
            piece = piece.strip()
            if not piece:
                continue
            try:
                office_ids_filter.add(int(piece))
            except ValueError:
                return jsonify({'error': f'office_ids must be numeric, got {piece}'}), 400

    summary_by_karat = {profile['label']: 0.0 for profile in karat_profiles}
    total_main = 0.0
    long_total = 0.0
    short_total = 0.0

    def build_breakdown(getter, accumulate=True):
        weights = {}
        normalized_total = 0.0
        for profile in karat_profiles:
            karat_value = profile['karat']
            if karat_filter and karat_value not in karat_filter:
                weights[profile['label']] = 0.0
                continue
            raw_value = parse_float(getter(profile['field']))
            weights[profile['label']] = round_weight(raw_value)
            if accumulate:
                summary_by_karat[profile['label']] += raw_value
            normalized_total += normalize_to_main(raw_value, karat_value)
        return weights, normalized_total

    account_rows = []
    accounts_query = Account.query.filter(Account.tracks_weight == True)
    for account in accounts_query:
        weights, normalized_total = build_breakdown(lambda field: getattr(account, field, 0.0))
        total_main += normalized_total
        if normalized_total > 0:
            long_total += normalized_total
        elif normalized_total < 0:
            short_total += normalized_total

        if not include_zero and abs(normalized_total) < min_variance:
            continue

        account_rows.append({
            'id': account.id,
            'account_number': account.account_number,
            'name': account.name,
            'type': account.type,
            'weights': weights,
            'total_main_karat': round_weight(normalized_total),
            'tracks_weight': account.tracks_weight,
        })

    top_long_accounts = [row for row in account_rows if row['total_main_karat'] > 0]
    top_long_accounts.sort(key=lambda entry: entry['total_main_karat'], reverse=True)
    top_long_accounts = top_long_accounts[:5]

    top_short_accounts = [row for row in account_rows if row['total_main_karat'] < 0]
    top_short_accounts.sort(key=lambda entry: entry['total_main_karat'])
    top_short_accounts = top_short_accounts[:5]

    safe_box_rows = []
    safe_boxes_query = SafeBox.query.filter(SafeBox.is_active.is_(True))
    if safe_types_filter:
        safe_boxes_query = safe_boxes_query.filter(SafeBox.safe_type.in_(safe_types_filter))

    for safe_box in safe_boxes_query.all():
        account = safe_box.account
        if not account or not account.tracks_weight:
            continue
        weights, normalized_total = build_breakdown(lambda field: getattr(account, field, 0.0), accumulate=False)
        if not include_zero and abs(normalized_total) < min_variance:
            continue

        safe_box_rows.append({
            'id': safe_box.id,
            'name': safe_box.name,
            'safe_type': safe_box.safe_type,
            'karat': safe_box.karat,
            'account_id': account.id,
            'account_number': account.account_number,
            'weights': weights,
            'total_main_karat': round_weight(normalized_total),
            'is_default': safe_box.is_default,
        })

    office_rows = []
    offices_query = Office.query
    if office_ids_filter:
        offices_query = offices_query.filter(Office.id.in_(office_ids_filter))
    else:
        offices_query = offices_query.filter(Office.active.is_(True))

    for office in offices_query.all():
        weights = {}
        normalized_total = 0.0
        for profile in karat_profiles:
            karat_val = profile['karat']
            if karat_filter and karat_val not in karat_filter:
                weights[profile['label']] = 0.0
                continue
            # Office fields are named balance_gold_XXk
            field_name = profile['field']
            office_field = field_name.replace('balance_', 'balance_gold_')
            raw_value = parse_float(getattr(office, office_field, 0.0))
            weights[profile['label']] = round_weight(raw_value)
            normalized_total += normalize_to_main(raw_value, karat_val)

        if not include_zero and abs(normalized_total) < min_variance:
            continue

        office_rows.append({
            'id': office.id,
            'name': office.name,
            'office_code': office.office_code,
            'weights': weights,
            'total_main_karat': round_weight(normalized_total),
            'active': office.active,
        })

    distribution = []
    distribution_total_main = 0.0
    for profile in karat_profiles:
        raw_total = summary_by_karat[profile['label']]
        normalized = normalize_to_main(raw_total, profile['karat'])
        distribution_total_main += normalized
        distribution.append({
            'karat': profile['label'],
            'raw_weight': round_weight(raw_total),
            'normalized_main_karat': round_weight(normalized),
        })

    latest_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    usd_to_sar_per_gram = SAR_USD_PEG / TROY_OZ_TO_GRAMS
    price_reference = None
    if latest_price and latest_price.price:
        per_gram_24k = round_weight(latest_price.price * usd_to_sar_per_gram)
        per_gram_main = round_weight(per_gram_24k * (main_karat / 24.0))
        price_reference = {
            'source_date': latest_price.date.isoformat() if latest_price.date else None,
            'price_usd_ounce': round_weight(latest_price.price),
            'price_sar_per_gram_24k': per_gram_24k,
            'price_sar_per_gram_main_karat': per_gram_main,
            'main_karat': main_karat,
        }

    estimated_value = None
    if price_reference:
        estimated_value = round_weight(total_main * price_reference['price_sar_per_gram_main_karat'])

    summary = {
        'total_by_karat': {
            profile['label']: round_weight(summary_by_karat[profile['label']])
            for profile in karat_profiles
        },
        'total_main_karat': round_weight(total_main),
        'long_position_main': round_weight(long_total),
        'short_position_main': round_weight(short_total),
        'net_position_main': round_weight(total_main),
        'distribution': distribution,
        'distribution_total_main': round_weight(distribution_total_main),
        'estimated_value_sar': estimated_value,
        'price_reference': price_reference,
        'main_karat': main_karat,
    }

    return jsonify({
        'summary': summary,
        'accounts': account_rows,
        'safe_boxes': safe_box_rows,
        'offices': office_rows,
        'top_long_accounts': top_long_accounts,
        'top_short_accounts': top_short_accounts,
        'filters': {
            'include_zero': include_zero,
            'min_variance': min_variance,
            'safe_types': list(safe_types_filter) if safe_types_filter else None,
            'office_ids': list(office_ids_filter) if office_ids_filter else None,
            'karats': list(karat_filter) if karat_filter else None,
        },
    })

# 🔥 النظام المزدوج: التقارير الوزنية
# ═══════════════════════════════════════════════════════════════

@reports_bp.route('/dual_system/income_statement', methods=['GET'])
@require_permission('reports.financial')
def get_weight_based_income_statement():
    """
    قائمة الدخل بالوزن المعادل
    تحسب الإيرادات والمصروفات بالجرام المعادل بناءً على أسعار الذهب
    وقت المعاملة (gold_price_snapshot)
    """
    try:
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')
        
        # التحقق من التواريخ
        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد تاريخ البداية والنهاية'}), 400
        
        start_date = datetime.strptime(start_date_str, '%Y-%m-%d')
        end_date = datetime.strptime(end_date_str, '%Y-%m-%d') + timedelta(days=1)

        # سعر الذهب المباشر (عيار 24) لتحويل النقد إلى وزن عند الحاجة
        latest_gold_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        live_gold_price_per_gram_24k = 0.0
        if latest_gold_price and latest_gold_price.price:
            live_gold_price_per_gram_24k = (latest_gold_price.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
        if live_gold_price_per_gram_24k <= 0:
            live_gold_price_per_gram_24k = 400.0  # fallback يمنع القسمة على صفر

        def cash_to_weight(net_cash: float, price_snapshot: float) -> float:
            price = price_snapshot or live_gold_price_per_gram_24k
            if price and price > 0:
                return net_cash / price
            return 0.0

        # سعر الذهب المباشر (عيار 24) لاستخدامه في تحويل النقد إلى وزن للمصنعية
        latest_gold_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        live_gold_price_per_gram_24k = 0.0
        if latest_gold_price and latest_gold_price.price:
            live_gold_price_per_gram_24k = (latest_gold_price.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
        if live_gold_price_per_gram_24k <= 0:
            live_gold_price_per_gram_24k = 400.0  # قيمة احتياطية لضمان عدم القسمة على صفر

        def cash_to_weight(net_cash: float, price_snapshot: float) -> float:
            price = price_snapshot or live_gold_price_per_gram_24k
            if price and price > 0:
                return net_cash / price
            return 0.0
        main_karat_value = get_main_karat() or 21
        
        # سعر الذهب المباشر (عيار 24) لتحويل الربح النقدي إلى وزن
        latest_gold_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        live_gold_price_per_gram_24k = 0.0
        gold_price_source = 'not_available'
        gold_price_updated_at = None
        if latest_gold_price and latest_gold_price.price:
            live_gold_price_per_gram_24k = (latest_gold_price.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
            gold_price_source = 'database'
            gold_price_updated_at = latest_gold_price.date.isoformat() if latest_gold_price.date else None
        if live_gold_price_per_gram_24k <= 0:
            live_gold_price_per_gram_24k = 400.0  # fallback value
            gold_price_source = 'fallback'
        
        # جلب قيود اليومية المرحّلة فقط في الفترة المحددة (مع استبعاد المحذوف)
        entries = db.session.query(JournalEntryLine).join(JournalEntry).filter(
            JournalEntry.date >= start_date,
            JournalEntry.date < end_date,
            or_(JournalEntry.is_posted == True, JournalEntry.is_posted.is_(None)),
            JournalEntry.is_deleted == False,
            JournalEntryLine.is_deleted == False
        ).all()
        
        # حسابات الإيرادات النقدية (لتحويلها إلى وزن بالسعر المباشر)
        revenue_accounts_cash = db.session.query(Account).filter(
            Account.account_number.like('4%'),
            ~Account.account_number.like('7%')
        ).all()
        revenue_cash_ids = {acc.id for acc in revenue_accounts_cash}

        # محوّل نقد → وزن باستخدام snapshot القيد أو السعر الحالي
        def cash_to_weight(net_cash: float, price_snapshot: float) -> float:
            price = price_snapshot or live_gold_price_per_gram_24k
            if price and price > 0:
                return net_cash / price
            return 0.0

        revenues_weight = defaultdict(float)

        for line in entries:
            if line.account_id in revenue_cash_ids:
                net_cash = (line.cash_credit or 0.0) - (line.cash_debit or 0.0)
                weight = cash_to_weight(net_cash, line.gold_price_snapshot)
                revenues_weight[line.account_id] += weight

        # ─────────────────────────────────────────────
        # الوزن الفعلي المباع من الفواتير (بيع/مرتجع بيع)
        # ─────────────────────────────────────────────
        actual_sold_weight = 0.0

        sale_invoice_types = ['بيع', 'مرتجع بيع']
        sale_invoices = (
            Invoice.query
            .filter(
                Invoice.date >= start_date,
                Invoice.date < end_date,
                Invoice.is_posted == True,
                Invoice.invoice_type.in_(sale_invoice_types)
            )
            .options(joinedload(Invoice.karat_lines), joinedload(Invoice.items))
            .all()
        )

        for inv in sale_invoices:
            direction = 1.0
            inv_type = (inv.invoice_type or '').strip()
            if 'مرتجع' in inv_type and 'بيع' in inv_type:
                direction = -1.0

            # v2: الوزن يُحسب من karat_lines/items بدون ضرب في qty
            weight_value = _invoice_weight_mk_v2(inv)

            if weight_value:
                actual_sold_weight += direction * float(weight_value)

        # مصروفات أجور المصنعية → تحويل من النقد إلى وزن بالسعر المباشر للسطر
        manufacturing_wage_acc_id = (
            get_account_id_for_mapping('بيع', 'manufacturing_wage')
            or _ensure_manufacturing_wage_expense_account()
            or get_account_id_by_number('51')
        )
        manufacturing_wage_weight = 0.0
        manufacturing_wage_details = []

        if manufacturing_wage_acc_id:
            for line in entries:
                if line.account_id == manufacturing_wage_acc_id:
                    net_cash = (line.cash_debit or 0.0) - (line.cash_credit or 0.0)
                    weight = cash_to_weight(net_cash, line.gold_price_snapshot)
                    if weight:
                        manufacturing_wage_weight += weight
                        manufacturing_wage_details.append({
                            'account_code': line.account.account_number if line.account else None,
                            'account_name': line.account.name if line.account else 'أجور مصنعية',
                            'weight_grams': round(weight, 6),
                            'price_snapshot': round(line.gold_price_snapshot, 2) if line.gold_price_snapshot else None
                        })

        # بناء التقرير
        revenue_details = []
        total_revenue_weight = 0.0
        
        for acc_id, weight in revenues_weight.items():
            if weight != 0:
                account = db.session.query(Account).get(acc_id)
                revenue_details.append({
                    'account_code': account.account_number,
                    'account_name': account.name,
                    'weight_grams': round(weight, 6)
                })
                total_revenue_weight += weight
        
        # تكلفة المبيعات الوزنية = الوزن الفعلي المباع
        total_cost_of_sales_weight = actual_sold_weight
        cost_of_sales_details = [{
            'account_code': 'actual_sold_weight',
            'account_name': 'الوزن الفعلي المباع (من الفواتير المرحّلة)',
            'weight_grams': round(actual_sold_weight, 6)
        }]
        
        # المصروفات الوزنية (حالياً: أجور المصنعية محولة للوزن)
        operating_expense_details = manufacturing_wage_details
        total_operating_expense_weight = manufacturing_wage_weight
        
        # حساب ربح الفواتير النقدي وتحويله إلى وزن بالعيار الرئيسي
        profit_cash_total = (
            db.session.query(func.coalesce(func.sum(Invoice.profit_cash), 0.0))
            .filter(
                Invoice.date >= start_date,
                Invoice.date < end_date,
                Invoice.is_posted == True,
                Invoice.invoice_type.in_(['بيع', 'مرتجع بيع'])
            )
            .scalar()
            or 0.0
        )

        profit_weight_grams_24k = (profit_cash_total / live_gold_price_per_gram_24k) if live_gold_price_per_gram_24k > 0 else 0.0
        profit_weight_main_karat = convert_to_main_karat(profit_weight_grams_24k, 24) if profit_weight_grams_24k else 0.0
        # صافي الوزن لحسابات المذكرة (غير مستخدم حالياً في العرض، يُترك للحفاظ على التوافق)
        memo_net_weight = total_revenue_weight - total_operating_expense_weight
        
        # حساب الربح الإجمالي والصافي
        gross_profit_weight = total_revenue_weight - total_cost_of_sales_weight
        net_profit_weight = gross_profit_weight - total_operating_expense_weight
        
        # حساب هامش الربح
        profit_margin_pct = (net_profit_weight / total_revenue_weight * 100) if total_revenue_weight > 0 else 0.0
        
        return jsonify({
            'start_date': start_date_str,
            'end_date': end_date_str,
            'report_type': 'weight_based_income_statement',
            
            # 1️⃣ صافي المبيعات وزن (الإيرادات)
            'net_sales_weight': {
                'total_weight_grams': round(total_revenue_weight, 6),
                'details': sorted(revenue_details, key=lambda x: x['account_code']),
                'note': 'صافي المبيعات بالوزن (من حسابات الإيرادات الوزنية 74xxx)'
            },
            
            # 2️⃣ الوزن المباع (تكلفة المبيعات الوزنية)
            'sold_weight': {
                'total_weight_grams': round(total_cost_of_sales_weight, 6),
                'details': sorted(cost_of_sales_details, key=lambda x: x['account_code']),
                'note': 'الوزن الفعلي المباع من الفواتير المرحّلة (بيع / مرتجع بيع)'
            },
            
            # 3️⃣ الربح الإجمالي الوزني
            'gross_profit_weight': {
                'total_weight_grams': round(gross_profit_weight, 6),
                'note': 'الربح الإجمالي الوزني = صافي المبيعات - الوزن المباع'
            },
            
            # 4️⃣ المصاريف الوزنية (أجور المصنعية + المصاريف التشغيلية)
            'operating_expenses_weight': {
                'total_weight_grams': round(total_operating_expense_weight, 6),
                'details': sorted(operating_expense_details, key=lambda x: x['account_code']),
                'note': 'المصاريف الوزنية (أجور المصنعية والمصاريف التشغيلية)'
            },
            
            # 5️⃣ صافي الربح الوزني
            'net_profit_weight': {
                'total_weight_grams': round(net_profit_weight, 6),
                'note': 'صافي الربح الوزني = الربح الإجمالي - المصاريف الوزنية'
            },
            
            # 6️⃣ هامش الربح
            'profit_margin': {
                'percentage': round(profit_margin_pct, 2),
                'note': 'هامش الربح % = (صافي الربح ÷ صافي المبيعات) × 100'
            },
            
            # معلومات السعر
            'pricing_info': {
                'live_gold_price_per_gram_24k': round(live_gold_price_per_gram_24k, 2) if live_gold_price_per_gram_24k else None,
                'source': gold_price_source,
                'updated_at': gold_price_updated_at,
                'main_karat_reference': main_karat_value
            }
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating weight-based income statement: {e}")
        return jsonify({'error': f'فشل إنشاء قائمة الدخل الوزنية: {str(e)}'}), 500

@reports_bp.route('/release-wage-weight', methods=['POST'])
@require_permission('journal.create')
def release_wage_weight():
    data = request.get_json(silent=True) or {}
    grams_raw = data.get('grams')
    note = data.get('note') or data.get('description') or 'تحرير وزن أجور المصنعية'
    karat_value = data.get('karat') or data.get('main_karat') or get_main_karat()

    try:
        grams_value = float(normalize_number(str(grams_raw))) if grams_raw not in (None, '') else 0.0
    except Exception:
        grams_value = 0.0

    if grams_value <= 0:
        return jsonify({'error': 'Invalid weight value'}), 400

    try:
        journal_entry = create_wage_weight_release_journal(
            weight_grams=grams_value,
            note=note,
            karat=karat_value
        )
    except ValueError as exc:
        db.session.rollback()
        return jsonify({'error': str(exc)}), 400
    except Exception as exc:
        db.session.rollback()
        print(f"❌ Error releasing wage weight: {exc}")
        return jsonify({'error': 'فشل تحرير وزن الأجور'}), 500

    return jsonify({
        'status': 'ok',
        'journal_entry_id': journal_entry.id,
        'entry_number': journal_entry.entry_number,
        'weight_grams': round(grams_value, 6)
    }), 201

@reports_bp.route('/dual_system/account_statement', methods=['GET'])
@require_permission('reports.financial')
def get_dual_account_statement():
    """
    كشف حساب مزدوج: يعرض النقد والوزن معاً
    """
    try:
        account_id = request.args.get('account_id', type=int)
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')
        
        if not account_id:
            return jsonify({'error': 'يجب تحديد رقم الحساب'}), 400
        
        account = db.session.query(Account).get(account_id)
        if not account:
            return jsonify({'error': 'الحساب غير موجود'}), 404
        
        # بناء الاستعلام
        query = db.session.query(JournalEntryLine).join(JournalEntry).filter(
            JournalEntryLine.account_id == account_id,
            JournalEntry.is_posted == True
        )
        
        if start_date_str:
            start_date = datetime.strptime(start_date_str, '%Y-%m-%d')
            query = query.filter(JournalEntry.date >= start_date)
        
        if end_date_str:
            end_date = datetime.strptime(end_date_str, '%Y-%m-%d')
            query = query.filter(JournalEntry.date <= end_date)
        
        lines = query.order_by(JournalEntry.date, JournalEntry.id).all()
        
        # حساب الأرصدة الجارية
        balance_cash = 0.0
        balance_weight = 0.0
        
        transactions = []
        for line in lines:
            balance_cash += line.cash_debit - line.cash_credit
            balance_weight += line.debit_weight - line.credit_weight
            
            transactions.append({
                'date': line.journal_entry.date.strftime('%Y-%m-%d'),
                'entry_number': line.journal_entry.entry_number,
                'description': line.journal_entry.description,
                'cash_debit': round(line.cash_debit, 2),
                'cash_credit': round(line.cash_credit, 2),
                'weight_debit': round(line.debit_weight, 6),
                'weight_credit': round(line.credit_weight, 6),
                'balance_cash': round(balance_cash, 2),
                'balance_weight': round(balance_weight, 6),
                'gold_price_snapshot': round(line.gold_price_snapshot, 2) if line.gold_price_snapshot else None
            })
        
        return jsonify({
            'account': {
                'id': account.id,
                'code': account.account_number,
                'name': account.name,
                'has_memo_account': account.memo_account_id is not None
            },
            'start_date': start_date_str,
            'end_date': end_date_str,
            'transactions': transactions,
            'final_balance_cash': round(balance_cash, 2),
            'final_balance_weight': round(balance_weight, 6)
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating dual account statement: {e}")
        return jsonify({'error': f'فشل إنشاء كشف الحساب المزدوج: {str(e)}'}), 500

# ═══════════════════════════════════════════════════════════════
# 📊 قائمة الدخل التقليدية (نقدية)
# ═══════════════════════════════════════════════════════════════

@reports_bp.route('/reports/income_statement', methods=['GET'])
@require_permission('reports.financial')
def get_income_statement():
    """
    قائمة الدخل (نقدية فقط)

    ملاحظة: تم حذف المؤشرات/الأقسام الوزنية من هذا التقرير لتجنب خلط
    مؤشرات الوزن مع قائمة الدخل المالية.
    """
    try:
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')
        
        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد تاريخ البداية والنهاية'}), 400
        
        start_date = datetime.strptime(start_date_str, '%Y-%m-%d')
        end_date = datetime.strptime(end_date_str, '%Y-%m-%d') + timedelta(days=1)

        # جلب قيود اليومية المرحّلة فقط
        entries = db.session.query(JournalEntryLine).join(JournalEntry).filter(
            JournalEntry.date >= start_date,
            JournalEntry.date < end_date,
            or_(JournalEntry.is_posted == True, JournalEntry.is_posted.is_(None))
        ).all()
        
        # حسابات الإيرادات (4xxx) والمصروفات (5xxx)
        revenue_accounts = db.session.query(Account).filter(
            Account.account_number.like('4%'),
            ~Account.account_number.like('7%')  # استبعاد حسابات المذكرة
        ).all()
        
        # تشمل المصروفات 5xxx (تكلفة/مصاريف) و6xxx (تشغيلية)، مع استبعاد 7xxx (مذكرة)
        expense_accounts = db.session.query(Account).filter(
            or_(
                Account.account_number.like('5%'),
                Account.account_number.like('6%')
            ),
            ~Account.account_number.like('7%')
        ).all()
        
        revenue_ids = {acc.id for acc in revenue_accounts}
        expense_ids = {acc.id for acc in expense_accounts}
        
        # حساب الإيرادات والمصروفات - النظام المالي
        revenues = defaultdict(float)
        expenses = defaultdict(float)
        
        for line in entries:
            # النظام المالي
            if line.account_id in revenue_ids:
                # الإيرادات: الدائن - المدين
                net_amount = line.cash_credit - line.cash_debit
                revenues[line.account_id] += net_amount
            elif line.account_id in expense_ids:
                # المصروفات: المدين - الدائن
                net_amount = line.cash_debit - line.cash_credit
                expenses[line.account_id] += net_amount
        
        # بناء التقرير
        revenue_details = []
        total_revenue = 0.0
        
        for acc_id, amount in revenues.items():
            if amount != 0:
                account = db.session.query(Account).get(acc_id)
                revenue_details.append({
                    'account_code': account.account_number,
                    'account_name': account.name,
                    'amount': round(amount, 2)
                })
                total_revenue += amount
        
        expense_details = []
        total_expense = 0.0

        for acc_id, amount in expenses.items():
            if amount != 0:
                account = db.session.query(Account).get(acc_id)
                expense_details.append({
                    'account_code': account.account_number,
                    'account_name': account.name,
                    'account_id': acc_id,
                    'amount': round(amount, 2)
                })
                total_expense += amount

        # تحديد حساب مصروفات المصنعية وإخراجها بشكل صريح
        # 
        # ⚠️ ملاحظة هيكلية: حساب 51 (أجور مصنعية)
        # - حالياً: 51 (رقم مكون من خانتين)
        # - محاسبياً أدق: 510 أو 511 (ثلاث خانات)
        # - السبب: تفادي التباس مع مجموعات أو parsing مستقبلي
        # - ليس خطأ، لكن تحسين هيكلي طويل المدى
        # - التغيير يتطلب: تعديل دليل الحسابات + migration للبيانات القديمة
        # ─────────────────────────────────────────────
        manufacturing_wage_acc_id = (
            get_account_id_for_mapping('بيع', 'manufacturing_wage')
            or _ensure_manufacturing_wage_expense_account()
            or get_account_id_by_number('51')  # يُفضل استبداله بـ 510 أو 511 مستقبلاً
        )

        manufacturing_wage_amount = 0.0
        manufacturing_wage_detail = None
        if manufacturing_wage_acc_id:
            for detail in expense_details:
                if detail.get('account_id') == manufacturing_wage_acc_id:
                    manufacturing_wage_amount = detail['amount']
                    manufacturing_wage_detail = detail
                    break

        # تقسيم المصروفات إلى تكلفة مبيعات ومصاريف تشغيلية (باستثناء مصروف المصنعية حتى نظهره مستقلاً)
        # 
        # ⚠️ ملاحظة مهمة عن COGS النقدي (5xxx):
        # - يجب تسجيل قيد تكلفة البضاعة المباعة عند كل عملية بيع
        # - يُحسب من متوسط تكلفة المخزون النقدية
        # - إذا ظهر total_cogs = 0، فهذا يعني عدم وجود قيود COGS (خطأ محاسبي)
        # - القيد الصحيح عند البيع:
        #   مدين: 501 (تكلفة بضاعة مباعة) - بمتوسط التكلفة
        #   دائن: 140 (مخزون) - نقدياً
        # ─────────────────────────────────────────────
        cost_of_goods_details = []
        operating_expense_details = []
        total_cogs = 0.0
        total_operating = 0.0

        # تشمل حسابات تكلفة المبيعات الشائعة 50xx و 52x، مع استثناء 51xx لأنها مصاريف تشغيلية وليست تكلفة مبيعات
        cost_prefixes = ('50', '52', '520')

        for detail in expense_details:
            if manufacturing_wage_detail and detail is manufacturing_wage_detail:
                # سيتم التعامل معه كمصروف مصنعية منفصل أدناه
                continue

            code = detail['account_code'] or ''
            if code.startswith(cost_prefixes):
                cost_of_goods_details.append(detail)
                total_cogs += detail['amount']
            else:
                operating_expense_details.append(detail)
                total_operating += detail['amount']

        # إضافة مصروف المصنعية إلى المصاريف التشغيلية الإجمالية (مع عرضه بشكل مستقل)
        operating_expenses_total = total_operating + manufacturing_wage_amount

        gross_profit = total_revenue - total_cogs
        net_income = gross_profit - operating_expenses_total
        
        # حساب النسب المئوية
        net_margin_pct = (net_income / total_revenue * 100) if total_revenue != 0 else 0.0
        
        return jsonify({
            'start_date': start_date_str,
            'end_date': end_date_str,
            'report_type': 'income_statement',
            'summary': {
                # المؤشرات المالية (نقدي)
                'net_revenue': round(total_revenue, 2),
                'gross_profit': round(gross_profit, 2),
                'operating_expenses': round(operating_expenses_total, 2),
                'operating_expenses_excl_wage': round(total_operating, 2),
                'manufacturing_wage_expense': round(manufacturing_wage_amount, 2),
                'net_profit': round(net_income, 2),
                'net_margin_pct': round(net_margin_pct, 2),
            },
            'series': [],  # يمكن إضافة بيانات السلاسل الزمنية لاحقاً
            'revenues': {
                'details': sorted(revenue_details, key=lambda x: x['account_code']),
                'total': round(total_revenue, 2)
            },
            'expenses': {
                'details': sorted(expense_details, key=lambda x: x['account_code']),
                'total': round(total_expense, 2)
            },
            'cost_of_goods_sold': {
                'details': sorted(cost_of_goods_details, key=lambda x: x['account_code']),
                'total': round(total_cogs, 2)
            },
            'gross_profit': round(gross_profit, 2),
            'operating_expenses': {
                'details': sorted(operating_expense_details, key=lambda x: x['account_code']),
                'total': round(total_operating, 2),
                'manufacturing_wage': manufacturing_wage_detail or {
                    'account_code': None,
                    'account_name': 'مصروفات أجور المصنعية',
                    'amount': round(manufacturing_wage_amount, 2),
                }
            },
            'manufacturing_wage_expense': {
                'amount': round(manufacturing_wage_amount, 2),
                'account': manufacturing_wage_detail['account_code'] if manufacturing_wage_detail else None,
                'name': manufacturing_wage_detail['account_name'] if manufacturing_wage_detail else 'مصروفات أجور المصنعية'
            },
            'expense_breakdown': sorted(
                ([manufacturing_wage_detail] if manufacturing_wage_detail else []) + operating_expense_details,
                key=lambda x: abs(x.get('amount', 0)),
                reverse=True
            )[:5],
            'net_income': round(net_income, 2)
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating income statement: {e}")
        return jsonify({'error': f'فشل إنشاء قائمة الدخل: {str(e)}'}), 500

# ══════════════════════════════════════════════════════════════════════════════
# 📊  تقرير ربح الجرام (طريقة طبقية)
#
#  الطبقة ① ربح المتاجرة = (متوسط بيع/جم − متوسط شراء/جم) × الوزن المباع
#  الطبقة ② إيرادات إضافية (وزنية + نقدية) من حسابات مفعّل عليها العلم
#  الطبقة ③ مصاريف وزنية مباشرة من حسابات مفعّل عليها العلم
#  الطبقة ④ مصاريف نقدية محوّلة لوزن من حسابات مفعّل عليها العلم
#
#  صافي الربح الوزني = ① + ② − ③ − ④
# ══════════════════════════════════════════════════════════════════════════════

@reports_bp.route('/reports/gram_profit', methods=['GET'])
@require_permission('reports.financial')
def get_gram_profit_report():
    """
    تقرير ربح الجرام الذهبي — آلية طبقية.
    """
    try:
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')

        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد start_date و end_date'}), 400

        start_dt = datetime.strptime(start_date_str, '%Y-%m-%d')
        end_dt = datetime.strptime(end_date_str, '%Y-%m-%d') + timedelta(days=1)

        main_karat = get_main_karat()  # 21 عادةً

        def _to_main(weight, karat):
            try:
                return float(weight or 0.0) * float(karat) / float(main_karat)
            except Exception:
                return 0.0

        def _inv_weight_in_main_karat(inv):
            """حساب وزن الفاتورة بالعيار الرئيسي."""
            total = 0.0
            kl = getattr(inv, 'karat_lines', None) or []
            if kl:
                for line in kl:
                    w = float(getattr(line, 'weight_grams', 0) or 0)
                    k = float(getattr(line, 'karat', main_karat) or main_karat)
                    if w > 0:
                        total += w * k / main_karat
                if total > 0:
                    return total
            inv_items = getattr(inv, 'items', None) or []
            if inv_items:
                for ii in inv_items:
                    w = float(getattr(ii, 'weight', 0) or 0)
                    k = float(getattr(ii, 'karat', 0) or 0)
                    if w > 0 and k > 0:
                        total += w * k / main_karat
                    else:
                        item_obj = getattr(ii, 'item', None)
                        if item_obj:
                            total += float(item_obj.weight_in_main_karat() or 0)
                if total > 0:
                    return total
            return float(inv.total_weight or 0.0)

        _inv_eager = (
            joinedload(Invoice.karat_lines),
            joinedload(Invoice.items).joinedload(InvoiceItem.item),
        )

        # ══════════════════════════════════════════════════════════════════
        # الطبقة ① — ربح المتاجرة (من الفواتير فقط)
        # ══════════════════════════════════════════════════════════════════

        # ── المبيعات ──
        sell_invoices = (
            Invoice.query
            .filter(Invoice.invoice_type.in_(['بيع', 'sell']))
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )
        sell_return_invoices = (
            Invoice.query
            .filter(Invoice.invoice_type.in_(['مرتجع بيع']))
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )

        total_sales_cash = 0.0
        total_weight_sold = 0.0
        for inv in sell_invoices:
            total_sales_cash += float(inv.total or 0.0)
            total_weight_sold += _inv_weight_in_main_karat(inv)
        for inv in sell_return_invoices:
            total_sales_cash -= float(inv.total or 0.0)
            total_weight_sold -= _inv_weight_in_main_karat(inv)

        avg_sell_per_gram = (
            total_sales_cash / total_weight_sold if total_weight_sold > 0 else 0.0
        )

        # ── المشتريات (لحساب avg_buy) ──
        customer_buy_invoices = (
            Invoice.query
            .filter(Invoice.invoice_type == 'شراء من عميل')
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )
        customer_buy_returns = (
            Invoice.query
            .filter(Invoice.invoice_type == 'مرتجع شراء')
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )
        settlement_buy_invoices = (
            Invoice.query
            .filter(Invoice.invoice_type.in_(['شراء', 'buy']))
            .filter(func.coalesce(Invoice.gold_type, '') == 'scrap')
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )
        supplier_buy_invoices = (
            Invoice.query
            .filter(Invoice.invoice_type.in_(['شراء', 'buy']))
            .filter(or_(
                func.coalesce(Invoice.gold_type, '') != 'scrap',
                Invoice.gold_type.is_(None),
            ))
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )
        supplier_buy_returns = (
            Invoice.query
            .filter(Invoice.invoice_type == 'مرتجع شراء (مورد)')
            .filter(Invoice.date >= start_dt, Invoice.date < end_dt)
            .filter(func.coalesce(Invoice.is_posted, False) == True)
            .options(*_inv_eager)
            .all()
        )

        total_purchases_cash = 0.0
        total_weight_purchased = 0.0
        for inv in customer_buy_invoices:
            total_purchases_cash += float(inv.total or 0.0)
            total_weight_purchased += _inv_weight_in_main_karat(inv)
        for inv in customer_buy_returns:
            total_purchases_cash -= float(inv.total or 0.0)
            total_weight_purchased -= _inv_weight_in_main_karat(inv)

        settlement_purchases_cash = 0.0
        settlement_weight_purchased = 0.0
        for inv in settlement_buy_invoices:
            settlement_purchases_cash += float(inv.total or 0.0)
            settlement_weight_purchased += _inv_weight_in_main_karat(inv)

        supplier_purchases_cash = 0.0
        supplier_weight_purchased = 0.0
        for inv in supplier_buy_invoices:
            supplier_purchases_cash += float(inv.total or 0.0)
            supplier_weight_purchased += _inv_weight_in_main_karat(inv)
        for inv in supplier_buy_returns:
            supplier_purchases_cash -= float(inv.total or 0.0)
            supplier_weight_purchased -= _inv_weight_in_main_karat(inv)

        cash_for_gold_purchases = total_purchases_cash + settlement_purchases_cash
        cash_for_gold_weight = total_weight_purchased + settlement_weight_purchased
        total_all_purchases_cash = cash_for_gold_purchases + supplier_purchases_cash
        total_all_weight_purchased = cash_for_gold_weight + supplier_weight_purchased

        # متوسط الشراء: عملاء + تسويات فقط (بدون موردين مصنّعة)
        avg_buy_per_gram = (
            cash_for_gold_purchases / cash_for_gold_weight
            if cash_for_gold_weight > 0 else 0.0
        )

        margin_per_gram = avg_sell_per_gram - avg_buy_per_gram
        trading_profit_cash = margin_per_gram * total_weight_sold
        # ══════════════════════════════════════════════════════════════════
        # الطبقات ② ③ ④ — من القيود اليومية على حسابات include_in_gram_profit
        # (مع وراثة: تفعيل الأب يشمل جميع أبنائه تلقائياً)
        # ══════════════════════════════════════════════════════════════════

        directly_flagged = (
            Account.query
            .filter(Account.include_in_gram_profit == True)
            .filter(func.coalesce(Account.exclude_from_gram_profit, False) == False)
            .all()
        )

        # جمع الأبناء لكل حساب مُفعّل (بحث تكراري)
        flagged_ids = {acc.id for acc in directly_flagged}

        # الحسابات المستثناة صراحةً (exclude_from_gram_profit=True)
        excluded_ids = {
            acc.id for acc in
            Account.query.filter(func.coalesce(Account.exclude_from_gram_profit, False) == True).all()
        }

        def _collect_descendants(parent_ids):
            if not parent_ids:
                return
            children = Account.query.filter(Account.parent_id.in_(parent_ids)).all()
            new_ids = set()
            for ch in children:
                if ch.id not in flagged_ids and ch.id not in excluded_ids:
                    flagged_ids.add(ch.id)
                    new_ids.add(ch.id)
            _collect_descendants(new_ids)

        _collect_descendants(flagged_ids.copy())

        # ── تضمين تلقائي للحسابات الوزنية التشغيلية (74xx / 75xx) ─────────────
        # نستثني مجموعتي المقابلات التجارية لأنهما محسوبتان في الطبقة ①:
        #   741xx = مقابلات المبيعات الوزنية  (Layer ① → trading_profit)
        #   751xx = مقابلات تكلفة المبيعات الوزنية (Layer ① → avg_buy)
        # ونستثني أيضاً أي حساب عليه exclude_from_gram_profit=True
        _counterpart_roots = Account.query.filter(
            Account.account_number.in_(['741', '751'])
        ).all()
        # D-3 FIX: جمع كل المنحدرين بشكل مُعادي — الفلتر الضحل (parent_id) لا يرى الأحفاد
        _counterpart_all_ids: set = {a.id for a in _counterpart_roots}

        def _collect_counterpart_descendants(parent_ids: set) -> None:
            if not parent_ids:
                return
            children = Account.query.filter(Account.parent_id.in_(parent_ids)).all()
            new_ids = {ch.id for ch in children if ch.id not in _counterpart_all_ids}
            _counterpart_all_ids.update(new_ids)
            _collect_counterpart_descendants(new_ids)

        _collect_counterpart_descendants({a.id for a in _counterpart_roots})

        weight_memo_accs = (
            Account.query
            .filter(or_(
                Account.account_number.like('74%'),
                Account.account_number.like('75%'),
            ))
            .filter(Account.id.notin_(_counterpart_all_ids))
            .filter(func.coalesce(Account.exclude_from_gram_profit, False) == False)
            .all()
        )
        for _wma in weight_memo_accs:
            if _wma.id not in excluded_ids:
                flagged_ids.add(_wma.id)
        # ────────────────────────────────────────────────────────────────────────

        # إزالة المستثنيين صراحةً من النهائية
        flagged_ids -= excluded_ids

        flagged_accounts = Account.query.filter(Account.id.in_(flagged_ids)).all() if flagged_ids else []

        revenue_account_ids = set()
        expense_account_ids = set()
        for acc in flagged_accounts:
            num = str(acc.account_number or '')
            # 4xxx = إيرادات مالية، 74xx = إيرادات وزنية (مذكرة)
            if num.startswith('4') or num.startswith('74'):
                revenue_account_ids.add(acc.id)
            # 5xxx/6xxx = مصاريف مالية، 75xx = مصاريف وزنية (مذكرة)
            elif num.startswith('5') or num.startswith('6') or num.startswith('75'):
                expense_account_ids.add(acc.id)

        all_flagged_ids = revenue_account_ids | expense_account_ids

        # جلب جميع سطور القيود على هذه الحسابات في الفترة
        flagged_lines = []
        if all_flagged_ids:
            flagged_lines = (
                db.session.query(JournalEntryLine)
                .join(JournalEntry)
                .filter(JournalEntryLine.account_id.in_(all_flagged_ids))
                .filter(JournalEntry.date >= start_dt, JournalEntry.date < end_dt)
                .filter(func.coalesce(JournalEntry.is_posted, False) == True)
                .filter(func.coalesce(JournalEntry.is_deleted, False) == False)
                .filter(func.coalesce(JournalEntryLine.is_deleted, False) == False)
                .all()
            )

        # بناء خريطة account_id → Account object
        acc_map = {acc.id: acc for acc in flagged_accounts}

        # ── الطبقة ② — إيرادات إضافية ──
        extra_revenue_weight = 0.0      # إيرادات وزنية مباشرة (جم 21)
        extra_revenue_cash = 0.0        # إيرادات نقدية (ر.س)
        extra_revenue_details = []

        # ── الطبقة ③ — مصاريف وزنية مباشرة ──
        expense_weight_direct = 0.0     # مصاريف وزنية (جم 21)
        expense_weight_details = []

        # ── الطبقة ④ — مصاريف نقدية ──
        expense_cash_total = 0.0        # مصاريف نقدية (ر.س)
        expense_cash_details = []

        for line in flagged_lines:
            acc_id = line.account_id
            acc = acc_map.get(acc_id)
            if not acc:
                continue
            acc_num = str(acc.account_number or '')
            acc_name = acc.name or ''

            # دالة مساعدة: تُجمّع جميع العيارات مُطبَّعةً إلى العيار الرئيسي
            def _normalized_21k(prefix):
                total = 0.0
                for karat in (18, 21, 22, 24):
                    field = f'{prefix}_{karat}k'
                    val = float(getattr(line, field, 0) or 0)
                    if val:
                        total += val * karat / main_karat
                return total

            # حساب الوزن المباشر:
            # - حسابات مالية (4/5/6): تستخدم debit_21k / credit_21k
            # - حسابات وزنية (74/75): تجمع جميع العيارات مُطبَّعةً إلى 21k
            #   وإلا fallback إلى debit_weight / credit_weight
            if acc_num.startswith('74') or acc_num.startswith('75'):
                w_debit = _normalized_21k('debit')
                w_credit = _normalized_21k('credit')
                # fallback إلى debit_weight إذا لم تتوفر أي حقول karat
                if w_debit == 0 and w_credit == 0:
                    w_debit = float(getattr(line, 'debit_weight', 0) or 0)
                    w_credit = float(getattr(line, 'credit_weight', 0) or 0)
            else:
                w_debit = float(getattr(line, 'debit_21k', 0) or 0)
                w_credit = float(getattr(line, 'credit_21k', 0) or 0)

            # حساب النقد
            c_debit = float(line.cash_debit or 0)
            c_credit = float(line.cash_credit or 0)

            if acc_id in revenue_account_ids:
                # إيرادات: credit = زيادة
                weight_net = w_credit - w_debit
                cash_net = c_credit - c_debit

                if abs(weight_net) > 0.0001:
                    extra_revenue_weight += weight_net
                    extra_revenue_details.append({
                        'account_number': acc_num,
                        'account_name': acc_name,
                        'type': 'weight',
                        'weight_grams': round(weight_net, 6),
                    })
                if abs(cash_net) > 0.01:
                    extra_revenue_cash += cash_net
                    extra_revenue_details.append({
                        'account_number': acc_num,
                        'account_name': acc_name,
                        'type': 'cash',
                        'cash_amount': round(cash_net, 2),
                    })

            elif acc_id in expense_account_ids:
                # مصاريف: debit = زيادة
                weight_net = w_debit - w_credit
                cash_net = c_debit - c_credit

                if abs(weight_net) > 0.0001:
                    expense_weight_direct += weight_net
                    expense_weight_details.append({
                        'account_number': acc_num,
                        'account_name': acc_name,
                        'type': 'weight',
                        'weight_grams': round(weight_net, 6),
                    })
                if abs(cash_net) > 0.01:
                    expense_cash_total += cash_net
                    expense_cash_details.append({
                        'account_number': acc_num,
                        'account_name': acc_name,
                        'type': 'cash',
                        'cash_amount': round(cash_net, 2),
                    })

        # تجميع التفاصيل حسب رقم الحساب (account_number) بدل سطر لكل قيد
        def _aggregate_details(raw_list, value_key):
            merged = {}
            for entry in raw_list:
                key = entry['account_number']
                if key not in merged:
                    merged[key] = {k: v for k, v in entry.items()}
                else:
                    merged[key][value_key] = round(
                        merged[key][value_key] + entry[value_key], 6
                    )
            # أزل الإدخالات التي صارت صفراً بعد التجميع
            return [e for e in merged.values() if abs(e[value_key]) > 0.0001]

        expense_weight_details  = _aggregate_details(expense_weight_details,  'weight_grams')
        expense_cash_details    = _aggregate_details(expense_cash_details,     'cash_amount')
        extra_revenue_details_w = _aggregate_details(
            [x for x in extra_revenue_details if x['type'] == 'weight'], 'weight_grams')
        extra_revenue_details_c = _aggregate_details(
            [x for x in extra_revenue_details if x['type'] == 'cash'],   'cash_amount')
        extra_revenue_details = extra_revenue_details_w + extra_revenue_details_c

        # إجمالي الطبقة ③ مستقلة عن avg_buy
        total_expense_weight_direct = expense_weight_direct
        # ربح المتاجرة النقدي (مستقل عن avg_buy)
        gross_profit = trading_profit_cash

        # ══════════════════════════════════════════════════════════════════
        # الحقول المشتقة من avg_buy — null عند avg_buy=0  (ADR-024 §D-1)
        # ══════════════════════════════════════════════════════════════════
        if avg_buy_per_gram > 0:
            trading_profit_weight        = trading_profit_cash / avg_buy_per_gram
            extra_revenue_cash_as_weight = extra_revenue_cash / avg_buy_per_gram
            expense_cash_as_weight       = expense_cash_total / avg_buy_per_gram
            total_extra_revenue_weight   = extra_revenue_weight + extra_revenue_cash_as_weight
            total_expense_cash_weight    = expense_cash_as_weight
            gross_profit_weight          = trading_profit_weight
            net_profit_weight            = (
                trading_profit_weight          # ① ربح المتاجرة
                + total_extra_revenue_weight   # ② إيرادات إضافية
                - total_expense_weight_direct  # ③ مصاريف وزنية
                - total_expense_cash_weight    # ④ مصاريف نقدية (محوّلة)
            )
            net_profit_cash      = net_profit_weight * avg_buy_per_gram
            net_margin_pct       = (net_profit_cash / total_sales_cash * 100) if total_sales_cash > 0 else 0.0
            total_oper_expenses  = expense_cash_total + expense_weight_direct * avg_buy_per_gram
            unavailable_reason   = None
        else:
            trading_profit_weight        = None
            extra_revenue_cash_as_weight = None
            expense_cash_as_weight       = None
            total_extra_revenue_weight   = None
            total_expense_cash_weight    = None
            gross_profit_weight          = None
            net_profit_weight            = None
            net_profit_cash              = None
            net_margin_pct               = None
            total_oper_expenses          = None
            unavailable_reason           = 'no_cash_purchases'

        def _rn(v, d=3):
            return round(v, d) if v is not None else None

        return jsonify({
            'start_date': start_date_str,
            'end_date': end_date_str,
            'report_type': 'gram_profit',
            'main_karat': main_karat,

            # الطبقة ① — ربح المتاجرة
            'weight_sold': round(total_weight_sold, 3),
            'weight_purchased': round(total_all_weight_purchased, 3),
            'weight_purchased_customer': round(total_weight_purchased, 3),
            'weight_purchased_supplier': round(supplier_weight_purchased, 3),
            'avg_sell_per_gram': round(avg_sell_per_gram, 2),
            'avg_buy_per_gram': round(avg_buy_per_gram, 2),
            'margin_per_gram': round(margin_per_gram, 2),
            'trading_profit_cash': round(trading_profit_cash, 2),
            'trading_profit_weight': _rn(trading_profit_weight, 3),
            'total_sales_cash': round(total_sales_cash, 2),
            'total_purchases_cash': round(total_all_purchases_cash, 2),
            'customer_purchases_cash': round(total_purchases_cash, 2),
            'settlement_purchases_cash': round(settlement_purchases_cash, 2),
            'settlement_weight_purchased': round(settlement_weight_purchased, 3),
            'supplier_purchases_cash': round(supplier_purchases_cash, 2),
            'supplier_weight_purchased': round(supplier_weight_purchased, 3),

            # الطبقة ② — إيرادات إضافية
            'extra_revenue_weight': round(extra_revenue_weight, 3),
            'extra_revenue_cash': round(extra_revenue_cash, 2),
            'extra_revenue_cash_as_weight': _rn(extra_revenue_cash_as_weight, 3),
            'total_extra_revenue_weight': _rn(total_extra_revenue_weight, 3),
            'extra_revenue_details': extra_revenue_details,

            # الطبقة ③ — مصاريف وزنية مباشرة
            'expense_weight_direct': round(total_expense_weight_direct, 3),
            'expense_weight_details': expense_weight_details,

            # الطبقة ④ — مصاريف نقدية (محوّلة)
            'expense_cash_total': round(expense_cash_total, 2),
            'expense_cash_as_weight': _rn(total_expense_cash_weight, 3),
            'expense_cash_details': expense_cash_details,

            # النتيجة النهائية
            'gross_profit': round(gross_profit, 2),
            'gross_profit_weight': _rn(gross_profit_weight, 3),
            'net_profit': _rn(net_profit_cash, 2),
            'net_profit_weight': _rn(net_profit_weight, 3),
            'net_margin_pct': _rn(net_margin_pct, 2),

            # حقول توافقية (backward compat)
            'manufacturing_wages': round(expense_cash_total, 2),
            'other_expenses': 0.0,
            'total_operating_expenses': _rn(total_oper_expenses, 2),
            'profit_after_wages': _rn(net_profit_cash, 2),
            'profit_after_wages_weight': _rn(net_profit_weight, 3),

            # سبب عدم التوفر (None إن كان المقياس محدداً)
            'unavailable_reason': unavailable_reason,
        }), 200

    except Exception as e:
        import traceback; traceback.print_exc()
        return jsonify({'error': f'فشل حساب ربح الجرام: {str(e)}'}), 500

# ==================== 🆕 Dual Chart of Accounts Endpoints ====================

@reports_bp.route('/reports/bridge-balance-monitor', methods=['GET'])
@require_permission('reports.financial')
def get_bridge_balance_monitor():
    """
    🆕 تقرير مراقبة رصيد حساب الجسر
    
    القاعدة الذهبية: رصيد حساب الجسر يجب أن يكون = صفر دائماً
    
    هذا التقرير:
    1. يعرض جميع حسابات الجسر في النظام
    2. يحدد أي حساب جسر به رصيد غير صفري
    3. يوفر تفاصيل للتحقيق في الخلل المحاسبي
    
    Returns:
    - bridge_accounts: قائمة حسابات الجسر مع أرصدتها
    - alerts: تحذيرات لأي حساب به رصيد غير صفري
    - status: 'balanced' أو 'unbalanced'
    """
    try:
        # البحث عن حسابات الجسر
        # 1. من الإعدادات المحاسبية
        bridge_mapping = AccountingMapping.query.filter(
            or_(
                AccountingMapping.mapping_key == 'supplier_bridge',
                AccountingMapping.mapping_key == 'customer_bridge',
                AccountingMapping.mapping_key.like('%bridge%')
            )
        ).all()
        
        bridge_account_ids = set()
        for mapping in bridge_mapping:
            if mapping.account_id:
                bridge_account_ids.add(mapping.account_id)
        
        # 2. من أسماء الحسابات التي تحتوي على "جسر"
        bridge_accounts_by_name = Account.query.filter(
            or_(
                Account.name.like('%جسر%'),
                Account.name.like('%bridge%'),
                Account.account_number.like('%999%')  # نمط شائع لحسابات الجسر
            )
        ).all()
        
        for acc in bridge_accounts_by_name:
            bridge_account_ids.add(acc.id)
        
        # جمع البيانات
        accounts_data = []
        alerts = []
        total_imbalance = 0.0
        
        for acc_id in bridge_account_ids:
            account = Account.query.get(acc_id)
            if not account:
                continue
            
            balance = account.balance_cash or 0.0
            
            # التحقق من التوازن (هامش خطأ 0.01)
            is_balanced = abs(balance) <= 0.01
            
            account_info = {
                'account_id': account.id,
                'account_number': account.account_number,
                'account_name': account.name,
                'balance': round(balance, 2),
                'is_balanced': is_balanced,
                'status': '✅ متوازن' if is_balanced else '⚠️ غير متوازن'
            }
            
            accounts_data.append(account_info)
            
            if not is_balanced:
                total_imbalance += abs(balance)
                alerts.append({
                    'severity': 'warning' if abs(balance) < 10 else 'error',
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'balance': round(balance, 2),
                    'message': f'حساب الجسر {account.account_number} ({account.name}) به رصيد غير صفري: {balance:.2f} ريال',
                    'recommendation': 'يرجى مراجعة القيود المحاسبية للفواتير المرتبطة بهذا الحساب'
                })
        
        overall_status = 'balanced' if len(alerts) == 0 else 'unbalanced'
        
        return jsonify({
            'status': overall_status,
            'summary': {
                'total_bridge_accounts': len(accounts_data),
                'balanced_accounts': sum(1 for acc in accounts_data if acc['is_balanced']),
                'unbalanced_accounts': sum(1 for acc in accounts_data if not acc['is_balanced']),
                'total_imbalance': round(total_imbalance, 2)
            },
            'bridge_accounts': accounts_data,
            'alerts': alerts,
            'notes': [
                '📌 القاعدة الذهبية: رصيد حساب الجسر = صفر دائماً',
                '⚠️ أي رصيد غير صفري يشير إلى خلل محاسبي',
                '🔍 يجب التحقيق في القيود المرتبطة بالحسابات غير المتوازنة',
                '💡 هامش الخطأ المسموح: ±0.01 ريال (للفواصل العشرية)'
            ]
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating bridge balance monitor: {e}")
        return jsonify({'error': f'فشل إنشاء تقرير مراقبة حساب الجسر: {str(e)}'}), 500

@reports_bp.route('/reports/trial-balance/cash', methods=['GET'])
@require_permission('reports.financial')
def get_cash_trial_balance():
    """
    ميزان المراجعة المالي (النقدي)
    
    يعرض أرصدة الحسابات من الشجرة المالية فقط (transaction_type='cash')
    
    Query Parameters:
    - date: تاريخ نهاية التقرير (YYYY-MM-DD) - افتراضي: اليوم
    
    Returns:
    - accounts: قائمة الحسابات مع أرصدتها
    - totals: إجماليات المدين والدائن والرصيد
    """
    try:
        end_date_str = request.args.get('date')
        if end_date_str:
            end_date = datetime.fromisoformat(end_date_str).date()
        else:
            end_date = datetime.now().date()
        
        # جلب جميع الحسابات النقدية
        cash_accounts = Account.query.filter_by(transaction_type='cash').order_by(Account.account_number).all()
        
        accounts_data = []
        total_debit = 0.0
        total_credit = 0.0
        
        for account in cash_accounts:
            # حساب الرصيد من القيود حتى التاريخ المحدد
            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == account.id,
                JournalEntry.date <= end_date
            ).all()
            
            debit_sum = sum(line.cash_debit or 0 for line in lines)
            credit_sum = sum(line.cash_credit or 0 for line in lines)
            balance = debit_sum - credit_sum
            
            # عرض فقط الحسابات التي لها رصيد أو حركة
            if abs(balance) > 0.001 or abs(debit_sum) > 0.001 or abs(credit_sum) > 0.001:
                accounts_data.append({
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'account_type': account.type,
                    'debit': round(debit_sum, 2),
                    'credit': round(credit_sum, 2),
                    'balance': round(balance, 2)
                })
                
                if balance > 0:
                    total_debit += balance
                else:
                    total_credit += abs(balance)
        
        return jsonify({
            'report_type': 'trial_balance_cash',
            'date': end_date.isoformat(),
            'accounts': accounts_data,
            'totals': {
                'total_debit': round(total_debit, 2),
                'total_credit': round(total_credit, 2),
                'difference': round(total_debit - total_credit, 2)
            }
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating cash trial balance: {e}")
        return jsonify({'error': f'فشل إنشاء ميزان المراجعة النقدي: {str(e)}'}), 500

@reports_bp.route('/reports/trial-balance/gold', methods=['GET'])
@require_permission('reports.financial')
def get_gold_trial_balance():
    """
    ميزان المراجعة الوزني (الذهب)
    
    يعرض أرصدة الحسابات من الشجرة الوزنية فقط (transaction_type='gold')
    
    Query Parameters:
    - date: تاريخ نهاية التقرير (YYYY-MM-DD) - افتراضي: اليوم
    - karat: العيار المطلوب (18, 21, 22, 24) - افتراضي: جميع الأعيرة محولة للعيار الرئيسي
    
    Returns:
    - accounts: قائمة الحسابات مع أرصدتها الوزنية
    - totals: إجماليات المدين والدائن بالجرامات
    """
    try:
        from config import MAIN_KARAT
        
        end_date_str = request.args.get('date')
        if end_date_str:
            end_date = datetime.fromisoformat(end_date_str).date()
        else:
            end_date = datetime.now().date()
        
        karat_filter = request.args.get('karat')
        main_karat = MAIN_KARAT or 21
        
        # جلب جميع الحسابات الوزنية
        gold_accounts = Account.query.filter_by(transaction_type='gold').order_by(Account.account_number).all()
        
        accounts_data = []
        total_debit = 0.0
        total_credit = 0.0
        
        for account in gold_accounts:
            # حساب الرصيد من القيود حتى التاريخ المحدد
            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == account.id,
                JournalEntry.date <= end_date
            ).all()
            
            # جمع الأوزان من جميع الأعيرة (محولة للعيار الرئيسي)
            debit_18k = sum(line.debit_18k or 0 for line in lines) * (18 / main_karat)
            debit_21k = sum(line.debit_21k or 0 for line in lines) * (21 / main_karat)
            debit_22k = sum(line.debit_22k or 0 for line in lines) * (22 / main_karat)
            debit_24k = sum(line.debit_24k or 0 for line in lines) * (24 / main_karat)
            
            credit_18k = sum(line.credit_18k or 0 for line in lines) * (18 / main_karat)
            credit_21k = sum(line.credit_21k or 0 for line in lines) * (21 / main_karat)
            credit_22k = sum(line.credit_22k or 0 for line in lines) * (22 / main_karat)
            credit_24k = sum(line.credit_24k or 0 for line in lines) * (24 / main_karat)
            
            total_debit_weight = debit_18k + debit_21k + debit_22k + debit_24k
            total_credit_weight = credit_18k + credit_21k + credit_22k + credit_24k
            balance_weight = total_debit_weight - total_credit_weight
            
            # عرض فقط الحسابات التي لها رصيد أو حركة
            if abs(balance_weight) > 0.001 or abs(total_debit_weight) > 0.001 or abs(total_credit_weight) > 0.001:
                accounts_data.append({
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'account_type': account.type,
                    'debit_grams': round(total_debit_weight, 3),
                    'credit_grams': round(total_credit_weight, 3),
                    'balance_grams': round(balance_weight, 3),
                    'main_karat': main_karat
                })
                
                if balance_weight > 0:
                    total_debit += balance_weight
                else:
                    total_credit += abs(balance_weight)
        
        return jsonify({
            'report_type': 'trial_balance_gold',
            'date': end_date.isoformat(),
            'main_karat': main_karat,
            'accounts': accounts_data,
            'totals': {
                'total_debit_grams': round(total_debit, 3),
                'total_credit_grams': round(total_credit, 3),
                'difference_grams': round(total_debit - total_credit, 3)
            }
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating gold trial balance: {e}")
        return jsonify({'error': f'فشل إنشاء ميزان المراجعة الوزني: {str(e)}'}), 500

@reports_bp.route('/reports/inventory_reconciliation', methods=['GET'])
@require_permission('reports.financial')
def get_inventory_reconciliation_report():
    """تقرير مطابقة المخزون المالي مع المخزون الوزني.

    يقارن بين:
    - حسابات المخزون المالية 13xx (قيمة بالريال)
    - وحسابات المخزون الوزنية 7131xx (وزن بالجرام محوّل للعيار الرئيسي)

    ويعرض لكل زوج (مالي ↔ وزني):
    - الرصيد المالي (ريال)
    - الرصيد الوزني (جرام)
    - نسبة القيمة لكل جرام (ريال/جرام) إن أمكن
    """
    try:
        from config import MAIN_KARAT

        end_date_str = request.args.get('date')
        if end_date_str:
            end_date = datetime.fromisoformat(end_date_str).date()
        else:
            end_date = datetime.now().date()

        main_karat = MAIN_KARAT or 21

        # 1) حساب أرصدة المخزون المالية 13xx
        financial_accounts = Account.query.filter(
            Account.account_number.like('13%'),
            Account.transaction_type.in_(['cash', 'both']),
        ).order_by(Account.account_number).all()

        financial_balances = {}
        for acc in financial_accounts:
            lines = (
                JournalEntryLine.query
                .join(JournalEntry)
                .filter(
                    JournalEntryLine.account_id == acc.id,
                    JournalEntry.date <= end_date,
                )
                .all()
            )

            debit_cash = sum(line.cash_debit or 0 for line in lines)
            credit_cash = sum(line.cash_credit or 0 for line in lines)
            balance_cash = debit_cash - credit_cash

            financial_balances[acc.account_number] = {
                'account': acc,
                'balance_cash': balance_cash,
            }

        # 2) حساب أرصدة المخزون الوزنية 7131xx (وزن محوَّل للعيار الرئيسي)
        gold_accounts = Account.query.filter(
            Account.account_number.like('7131%'),
            Account.transaction_type == 'gold',
        ).order_by(Account.account_number).all()

        gold_balances = {}
        for acc in gold_accounts:
            lines = (
                JournalEntryLine.query
                .join(JournalEntry)
                .filter(
                    JournalEntryLine.account_id == acc.id,
                    JournalEntry.date <= end_date,
                )
                .all()
            )

            debit_18k = sum(line.debit_18k or 0 for line in lines) * (18 / main_karat)
            debit_21k = sum(line.debit_21k or 0 for line in lines) * (21 / main_karat)
            debit_22k = sum(line.debit_22k or 0 for line in lines) * (22 / main_karat)
            debit_24k = sum(line.debit_24k or 0 for line in lines) * (24 / main_karat)

            credit_18k = sum(line.credit_18k or 0 for line in lines) * (18 / main_karat)
            credit_21k = sum(line.credit_21k or 0 for line in lines) * (21 / main_karat)
            credit_22k = sum(line.credit_22k or 0 for line in lines) * (22 / main_karat)
            credit_24k = sum(line.credit_24k or 0 for line in lines) * (24 / main_karat)

            total_debit_weight = debit_18k + debit_21k + debit_22k + debit_24k
            total_credit_weight = credit_18k + credit_21k + credit_22k + credit_24k
            balance_weight = total_debit_weight - total_credit_weight

            gold_balances[acc.account_number] = {
                'account': acc,
                'balance_grams': balance_weight,
            }

        # 3) مطابقة 1310 ↔ 71310, 1320 ↔ 71320, 1340 ↔ 71330 ... الخ
        rows = []
        all_numbers = sorted(set(list(financial_balances.keys()) + list(gold_balances.keys())))

        for number in all_numbers:
            fin = financial_balances.get(number)
            # نظير وزني متوقع بإضافة 7 في البداية (إن لم يكن 7131xx مباشرة)
            expected_gold_number = None
            if number.startswith('13') and not number.startswith('7131'):
                # مثال: 1310 → 71310
                expected_gold_number = '7' + number
            else:
                expected_gold_number = number

            gold = gold_balances.get(expected_gold_number)

            balance_cash = fin['balance_cash'] if fin else 0.0
            balance_grams = gold['balance_grams'] if gold else 0.0

            price_per_gram = None
            if balance_grams and abs(balance_grams) > 0.0001:
                price_per_gram = balance_cash / balance_grams

            rows.append({
                'financial_account': fin['account'].account_number if fin else number,
                'financial_name': fin['account'].name if fin else None,
                'gold_account': gold['account'].account_number if gold else expected_gold_number,
                'gold_name': gold['account'].name if gold else None,
                'balance_cash': round(float(balance_cash or 0.0), 2),
                'balance_grams': round(float(balance_grams or 0.0), 3),
                'price_per_gram': round(float(price_per_gram), 2) if price_per_gram is not None else None,
            })

        return jsonify({
            'report_type': 'inventory_reconciliation',
            'date': end_date.isoformat(),
            'main_karat': main_karat,
            'rows': rows,
        }), 200

    except Exception as e:
        print(f"❌ Error generating inventory reconciliation report: {e}")
        return jsonify({'error': f'فشل إنشاء تقرير مطابقة المخزون: {str(e)}'}), 500

@reports_bp.route('/reports/gold-weight-trial-balance', methods=['GET'])
@require_permission('reports.financial')
def get_gold_weight_trial_balance_by_safe_box():
    """ميزان مراجعة الأوزان (مطابقة الخزائن ↔ الحسابات الوزنية المرتبطة).

    الهدف:
    - جرد أرصدة كل خزنة ذهب من دفتر الخزينة (SafeBoxTransaction)
    - مقارنة الرصيد مع الحساب الوزني المرتبط (عادةً 7xxx) من القيود اليومية
    - إظهار الفرق (Variance) لاكتشاف أي تعديل يدوي على الحساب دون دفتر الخزنة (أو العكس)

    Query Parameters:
    - date: تاريخ نهاية التقرير (YYYY-MM-DD) - افتراضي: اليوم

    Returns:
    - rows: لكل خزنة: رصيد الخزنة، رصيد الحساب، والفرق لكل عيار + إجمالي محول للعيار الرئيسي
    """
    try:
        from config import MAIN_KARAT

        end_date_str = request.args.get('date')
        if end_date_str:
            end_date = datetime.fromisoformat(end_date_str).date()
        else:
            end_date = datetime.now().date()

        main_karat = float(MAIN_KARAT or 21)
        end_dt = datetime.combine(end_date, time.max)

        def _to_float(v):
            try:
                return float(v or 0.0)
            except Exception:
                return 0.0

        def _normalize_to_main(weight: float, karat: int) -> float:
            k = float(karat)
            if main_karat <= 0:
                return float(weight or 0.0)
            return float(weight or 0.0) * (k / main_karat)

        def _total_main_from_by_karat(by_karat: dict) -> float:
            return (
                _normalize_to_main(_to_float(by_karat.get('18k')), 18)
                + _normalize_to_main(_to_float(by_karat.get('21k')), 21)
                + _normalize_to_main(_to_float(by_karat.get('22k')), 22)
                + _normalize_to_main(_to_float(by_karat.get('24k')), 24)
            )

        def _safe_ledger_balance_by_karat(safe_id: int) -> dict:
            # Use SQL aggregates for performance.
            sign = case(
                (SafeBoxTransaction.direction == 'in', 1.0),
                else_=-1.0,
            )
            sums = (
                db.session.query(
                    func.coalesce(func.sum(SafeBoxTransaction.weight_18k * sign), 0.0).label('b18'),
                    func.coalesce(func.sum(SafeBoxTransaction.weight_21k * sign), 0.0).label('b21'),
                    func.coalesce(func.sum(SafeBoxTransaction.weight_22k * sign), 0.0).label('b22'),
                    func.coalesce(func.sum(SafeBoxTransaction.weight_24k * sign), 0.0).label('b24'),
                )
                .filter(SafeBoxTransaction.safe_box_id == safe_id)
                .filter(SafeBoxTransaction.created_at <= end_dt)
                .first()
            )

            by_karat = {
                '18k': round(_to_float(getattr(sums, 'b18', 0.0)), 3),
                '21k': round(_to_float(getattr(sums, 'b21', 0.0)), 3),
                '22k': round(_to_float(getattr(sums, 'b22', 0.0)), 3),
                '24k': round(_to_float(getattr(sums, 'b24', 0.0)), 3),
            }
            return {
                'by_karat': by_karat,
                'total_main_karat': round(_total_main_from_by_karat(by_karat), 3),
                'main_karat': int(main_karat),
            }

        def _account_balance_by_karat(account_id: int) -> dict:
            if not account_id:
                by_karat = {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
                return {
                    'by_karat': by_karat,
                    'total_main_karat': 0.0,
                    'main_karat': int(main_karat),
                }

            sums = (
                db.session.query(
                    func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0).label('d18'),
                    func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0).label('c18'),
                    func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0).label('d21'),
                    func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0).label('c21'),
                    func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0).label('d22'),
                    func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0).label('c22'),
                    func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0).label('d24'),
                    func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0).label('c24'),
                )
                .join(JournalEntry)
                .filter(JournalEntryLine.account_id == account_id)
                .filter(JournalEntry.date <= end_date)
                .first()
            )

            b18 = _to_float(getattr(sums, 'd18', 0.0)) - _to_float(getattr(sums, 'c18', 0.0))
            b21 = _to_float(getattr(sums, 'd21', 0.0)) - _to_float(getattr(sums, 'c21', 0.0))
            b22 = _to_float(getattr(sums, 'd22', 0.0)) - _to_float(getattr(sums, 'c22', 0.0))
            b24 = _to_float(getattr(sums, 'd24', 0.0)) - _to_float(getattr(sums, 'c24', 0.0))

            by_karat = {
                '18k': round(b18, 3),
                '21k': round(b21, 3),
                '22k': round(b22, 3),
                '24k': round(b24, 3),
            }
            return {
                'by_karat': by_karat,
                'total_main_karat': round(_total_main_from_by_karat(by_karat), 3),
                'main_karat': int(main_karat),
            }

        def _variance(a: dict, b: dict) -> dict:
            by_karat = {
                '18k': round(_to_float(a.get('18k')) - _to_float(b.get('18k')), 3),
                '21k': round(_to_float(a.get('21k')) - _to_float(b.get('21k')), 3),
                '22k': round(_to_float(a.get('22k')) - _to_float(b.get('22k')), 3),
                '24k': round(_to_float(a.get('24k')) - _to_float(b.get('24k')), 3),
            }
            total_main = round(_total_main_from_by_karat(by_karat), 3)
            return {
                'by_karat': by_karat,
                'total_main_karat': total_main,
                'main_karat': int(main_karat),
            }

        safes = (
            SafeBox.query
            .filter(SafeBox.safe_type == 'gold')
            .order_by(SafeBox.is_active.desc(), SafeBox.name.asc())
            .all()
        )

        rows = []
        balanced_count = 0
        total_variance_main = 0.0

        for sb in safes:
            safe_bal = _safe_ledger_balance_by_karat(int(sb.id))
            acc = Account.query.get(sb.account_id) if sb.account_id else None
            acc_bal = _account_balance_by_karat(int(sb.account_id) if sb.account_id else 0)

            var = _variance(safe_bal['by_karat'], acc_bal['by_karat'])

            # Consider balanced when variance is within a tiny tolerance.
            tol = 0.0005
            is_balanced = (
                abs(_to_float(var.get('total_main_karat'))) < tol
                and all(abs(_to_float(v)) < tol for v in (var.get('by_karat') or {}).values())
            )

            if is_balanced:
                balanced_count += 1
            total_variance_main += abs(_to_float(var.get('total_main_karat')))

            rows.append({
                'safe_box': {
                    'id': sb.id,
                    'name': sb.name,
                    'safe_type': sb.safe_type,
                    'karat': sb.karat,
                    'is_active': bool(sb.is_active),
                    'account_id': sb.account_id,
                    'account_number': acc.account_number if acc else None,
                    'account_name': acc.name if acc else None,
                },
                'safe_balance': safe_bal,
                'account_balance': acc_bal,
                'variance': var,
                'is_balanced': bool(is_balanced),
            })

        return jsonify({
            'report_type': 'gold_weight_trial_balance',
            'date': end_date.isoformat(),
            'main_karat': int(main_karat),
            'rows': rows,
            'summary': {
                'total_safe_boxes': len(rows),
                'balanced_safe_boxes': balanced_count,
                'unbalanced_safe_boxes': len(rows) - balanced_count,
                'total_abs_variance_main_karat': round(float(total_variance_main), 3),
            },
        }), 200

    except ValueError:
        return jsonify({'error': 'صيغة التاريخ غير صحيحة. استخدم YYYY-MM-DD'}), 400
    except Exception as e:
        print(f"❌ Error generating gold weight trial balance by safe box: {e}")
        return jsonify({'error': f'فشل إنشاء ميزان مراجعة الأوزان: {str(e)}'}), 500

@reports_bp.route('/reports/income-statement/cash', methods=['GET'])
@require_permission('reports.financial')
def get_cash_income_statement():
    """
    قائمة الدخل المالية (النقدي)
    
    تعرض الإيرادات والمصروفات من الشجرة المالية فقط
    
    Query Parameters:
    - start_date: تاريخ البداية (YYYY-MM-DD)
    - end_date: تاريخ النهاية (YYYY-MM-DD)
    
    Returns:
    - revenues: الإيرادات (حسابات 40x)
    - expenses: المصروفات (حسابات 50x)
    - net_income: صافي الربح بالريال
    """
    try:
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')

        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد تاريخ البداية والنهاية'}), 400

        start_date = datetime.fromisoformat(start_date_str).date()
        end_date = datetime.fromisoformat(end_date_str).date()

        # ---------- صافي المبيعات النقدية ----------
        revenue_accounts = Account.query.filter(
            Account.transaction_type.in_(['cash', 'both']),
            Account.account_number.like('4%')
        ).all()

        revenues_data = []
        total_revenue = 0.0
        for account in revenue_accounts:
            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == account.id,
                JournalEntry.date >= start_date,
                JournalEntry.date <= end_date
            ).all()

            credit_sum = sum(line.cash_credit or 0 for line in lines)
            debit_sum = sum(line.cash_debit or 0 for line in lines)
            net_revenue = credit_sum - debit_sum

            if abs(net_revenue) > 0.01:
                revenues_data.append({
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'amount': round(net_revenue, 2)
                })
                total_revenue += net_revenue

        # ---------- تكلفة المبيعات النقدية (بدون المصنعية) ----------
        # نجمع أوزان الأصناف المباعه من karat lines، ثم نضرب كل عيار في متوسط سعر الشراء لذلك العيار
        sold_weights = {}
        cost_of_sales_details = []
        total_cost_of_sales = 0.0

        for karat in (18, 21, 22, 24):
            sold_weight = db.session.query(func.coalesce(func.sum(InvoiceKaratLine.weight_grams), 0.0)).join(Invoice).filter(
                InvoiceKaratLine.karat == str(karat),
                Invoice.date >= start_date,
                Invoice.date <= end_date,
                Invoice.is_posted == True,
                Invoice.invoice_type.in_(['بيع'])
            ).scalar() or 0.0

            if sold_weight and sold_weight > 0:
                avg_cost = get_inventory_average_cost(karat) or 0.0
                cost = round(sold_weight * avg_cost, 2)
                sold_weights[str(karat)] = sold_weight
                cost_of_sales_details.append({
                    'karat': str(karat),
                    'weight_grams': round(sold_weight, 3),
                    'avg_cost_per_gram': round(avg_cost, 2),
                    'cost': cost
                })
                total_cost_of_sales += cost

        # ---------- المصاريف: أجور المصنعية + المصاريف التشغيلية ----------
        # حساب أجور المصنعية المسجلة كمصروف (الحساب المخصص أو الحساب العام 51)
        manufacturing_wage_expense_acc_id = (
            get_account_id_for_mapping('بيع', 'manufacturing_wage')
            or _ensure_manufacturing_wage_expense_account()
            or get_account_id_for_mapping('بيع', 'operating_expenses')
            or get_account_id_by_number('51')
        )

        manufacturing_wage_amount = 0.0
        manufacturing_wage_details = []
        if manufacturing_wage_expense_acc_id:
            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == manufacturing_wage_expense_acc_id,
                JournalEntry.date >= start_date,
                JournalEntry.date <= end_date
            ).all()
            debit_sum = sum(line.cash_debit or 0 for line in lines)
            credit_sum = sum(line.cash_credit or 0 for line in lines)
            manufacturing_wage_amount = round(debit_sum - credit_sum, 2)
            if abs(manufacturing_wage_amount) > 0.01:
                acc = Account.query.get(manufacturing_wage_expense_acc_id)
                manufacturing_wage_details.append({
                    'account_number': acc.account_number if acc else None,
                    'account_name': acc.name if acc else 'مصروفات مصنعية',
                    'amount': manufacturing_wage_amount
                })

        # حساب المصاريف التشغيلية (حسابات 5x) باستثناء تكلفة المبيعات (50x) وأي حساب مصروف مصنعية تم احتسابه أعلاه
        expense_accounts = Account.query.filter(
            Account.transaction_type.in_(['cash', 'both']),
            Account.account_number.like('5%')
        ).all()

        operating_expenses_details = []
        total_operating_expenses = 0.0
        for account in expense_accounts:
            # استبعد حساب 50x (تكلفة المبيعات) لأننا حسبناها أعلاه
            if (account.account_number or '').startswith('50'):
                continue
            if manufacturing_wage_expense_acc_id and account.id == manufacturing_wage_expense_acc_id:
                # تم حسابه بالفعل
                continue

            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == account.id,
                JournalEntry.date >= start_date,
                JournalEntry.date <= end_date
            ).all()
            debit_sum = sum(line.cash_debit or 0 for line in lines)
            credit_sum = sum(line.cash_credit or 0 for line in lines)
            net_exp = round(debit_sum - credit_sum, 2)
            if abs(net_exp) > 0.01:
                operating_expenses_details.append({
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'amount': net_exp
                })
                total_operating_expenses += net_exp

        total_expenses = round((manufacturing_wage_amount or 0.0) + (total_operating_expenses or 0.0), 2)

        # ---------- المجاميع النهائية ----------
        gross_profit = round(total_revenue - total_cost_of_sales, 2)
        net_profit = round(gross_profit - total_expenses, 2)
        profit_margin_pct = round((net_profit / total_revenue * 100) if total_revenue > 0 else 0.0, 2)

        return jsonify({
            'report_type': 'income_statement_cash',
            'start_date': start_date_str,
            'end_date': end_date_str,

            # 1️⃣ صافي المبيعات
            'net_sales': {
                'total': round(total_revenue, 2),
                'details': sorted(revenues_data, key=lambda x: x['account_number'])
            },

            # 2️⃣ تكلفة المبيعات (الوزن × متوسط سعر الشراء للجرام) - بدون المصنعية
            'cost_of_sales': {
                'total': round(total_cost_of_sales, 2),
                'details': sorted(cost_of_sales_details, key=lambda x: x['karat'])
            },

            # 3️⃣ الربح النقدي (إجمالي)
            'gross_profit': {
                'total': gross_profit,
                'note': 'الربح الإجمالي = صافي المبيعات - تكلفة المبيعات'
            },

            # 4️⃣ المصاريف (أجور المصنعية + المصاريف التشغيلية)
            'expenses': {
                'manufacturing_wages': {
                    'total': manufacturing_wage_amount,
                    'details': manufacturing_wage_details
                },
                'operating_expenses': {
                    'total': round(total_operating_expenses, 2),
                    'details': sorted(operating_expenses_details, key=lambda x: x['account_number'])
                },
                'total': total_expenses
            },

            # 5️⃣ صافي الربح
            'net_profit': {
                'total': net_profit
            },

            # 6️⃣ هامش الربح
            'profit_margin_pct': profit_margin_pct
        }), 200

    except Exception as e:
        print(f"❌ Error generating cash income statement: {e}")
        return jsonify({'error': f'فشل إنشاء قائمة الدخل النقدية: {str(e)}'}), 500

@reports_bp.route('/reports/income-statement/gold', methods=['GET'])
@require_permission('reports.financial')
def get_gold_income_statement():
    """
    قائمة الدخل الوزنية (الذهب)
    
    تعرض الإيرادات والمصروفات من الشجرة الوزنية فقط
    
    Query Parameters:
    - start_date: تاريخ البداية (YYYY-MM-DD)
    - end_date: تاريخ النهاية (YYYY-MM-DD)
    
    Returns:
    - revenues: الإيرادات بالجرامات (حسابات 4Wx)
    - expenses: المصروفات بالجرامات (حسابات 5Wx)
    - net_profit_grams: صافي الربح بالجرامات
    """
    try:
        from config import MAIN_KARAT
        
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')
        
        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد تاريخ البداية والنهاية'}), 400
        
        start_date = datetime.fromisoformat(start_date_str).date()
        end_date = datetime.fromisoformat(end_date_str).date()
        main_karat = MAIN_KARAT or 21
        
        # جلب حسابات الإيرادات (74xx) من شجرة المذكرة
        revenue_accounts = Account.query.filter(
            Account.transaction_type == 'gold',
            Account.account_number.like('74%')
        ).all()
        
        # جلب حسابات المصروفات (75xx) من شجرة المذكرة
        expense_accounts = Account.query.filter(
            Account.transaction_type == 'gold',
            Account.account_number.like('75%')
        ).all()
        
        revenues_data = []
        total_revenue_grams = 0.0
        
        for account in revenue_accounts:
            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == account.id,
                JournalEntry.date >= start_date,
                JournalEntry.date <= end_date
            ).all()
            
            # جمع الأوزان من جميع الأعيرة (محولة للعيار الرئيسي)
            credit_18k = sum(line.credit_18k or 0 for line in lines) * (18 / main_karat)
            credit_21k = sum(line.credit_21k or 0 for line in lines) * (21 / main_karat)
            credit_22k = sum(line.credit_22k or 0 for line in lines) * (22 / main_karat)
            credit_24k = sum(line.credit_24k or 0 for line in lines) * (24 / main_karat)
            
            debit_18k = sum(line.debit_18k or 0 for line in lines) * (18 / main_karat)
            debit_21k = sum(line.debit_21k or 0 for line in lines) * (21 / main_karat)
            debit_22k = sum(line.debit_22k or 0 for line in lines) * (22 / main_karat)
            debit_24k = sum(line.debit_24k or 0 for line in lines) * (24 / main_karat)
            
            total_credit = credit_18k + credit_21k + credit_22k + credit_24k
            total_debit = debit_18k + debit_21k + debit_22k + debit_24k
            net_revenue = total_credit - total_debit  # الإيرادات دائنة
            
            if abs(net_revenue) > 0.001:
                revenues_data.append({
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'amount_grams': round(net_revenue, 3)
                })
                total_revenue_grams += net_revenue
        
        expenses_data = []
        total_expense_grams = 0.0
        
        for account in expense_accounts:
            lines = JournalEntryLine.query.join(JournalEntry).filter(
                JournalEntryLine.account_id == account.id,
                JournalEntry.date >= start_date,
                JournalEntry.date <= end_date
            ).all()
            
            # جمع الأوزان من جميع الأعيرة (محولة للعيار الرئيسي)
            debit_18k = sum(line.debit_18k or 0 for line in lines) * (18 / main_karat)
            debit_21k = sum(line.debit_21k or 0 for line in lines) * (21 / main_karat)
            debit_22k = sum(line.debit_22k or 0 for line in lines) * (22 / main_karat)
            debit_24k = sum(line.debit_24k or 0 for line in lines) * (24 / main_karat)
            
            credit_18k = sum(line.credit_18k or 0 for line in lines) * (18 / main_karat)
            credit_21k = sum(line.credit_21k or 0 for line in lines) * (21 / main_karat)
            credit_22k = sum(line.credit_22k or 0 for line in lines) * (22 / main_karat)
            credit_24k = sum(line.credit_24k or 0 for line in lines) * (24 / main_karat)
            
            total_debit = debit_18k + debit_21k + debit_22k + debit_24k
            total_credit = credit_18k + credit_21k + credit_22k + credit_24k
            net_expense = total_debit - total_credit  # المصروفات مدينة
            
            if abs(net_expense) > 0.001:
                expenses_data.append({
                    'account_number': account.account_number,
                    'account_name': account.name,
                    'amount_grams': round(net_expense, 3)
                })
                total_expense_grams += net_expense
        
        net_profit_grams = total_revenue_grams - total_expense_grams
        net_margin_pct = (net_profit_grams / total_revenue_grams * 100) if total_revenue_grams > 0 else 0.0
        
        return jsonify({
            'report_type': 'income_statement_gold',
            'start_date': start_date_str,
            'end_date': end_date_str,
            'main_karat': main_karat,
            'revenues': {
                'details': revenues_data,
                'total_grams': round(total_revenue_grams, 3)
            },
            'expenses': {
                'details': expenses_data,
                'total_grams': round(total_expense_grams, 3)
            },
            'net_profit_grams': round(net_profit_grams, 3),
            'net_margin_pct': round(net_margin_pct, 2)
        }), 200
        
    except Exception as e:
        print(f"❌ Error generating gold income statement: {e}")
        return jsonify({'error': f'فشل إنشاء قائمة الدخل الوزنية: {str(e)}'}), 500

@reports_bp.route('/dashboard/summary-debug', methods=['GET'])
@require_permission('admin')
def get_dashboard_summary_debug():
    """Debug endpoint: run _build_inv_summary for month and return raw result + any errors."""
    import traceback as _tb
    from datetime import datetime as _dt, timedelta as _td
    now = _dt.now()
    today_start = _dt.combine(now.date(), _dt.min.time())
    tomorrow_start = today_start + _td(days=1)
    month_start = _dt(now.year, now.month, 1)
    year_start = _dt(now.year, 1, 1)

    sale_types = {'بيع': 1, 'sell': 1, 'sale': 1, 'مرتجع بيع': -1}
    purchase_types = {'شراء': 1, 'شراء من عميل': 1, 'مرتجع شراء': -1, 'مرتجع شراء (مورد)': -1}

    def _try_summary(inv_types_dict, start, end):
        try:
            inv_types = [str(t).strip() for t in inv_types_dict.keys() if str(t).strip()]
            q = (
                Invoice.query
                .filter(Invoice.invoice_type.in_(inv_types))
                .filter(Invoice.is_posted.is_(True))
                .filter(Invoice.date >= start)
                .filter(Invoice.date < end)
            )
            rows = q.all()
            return {'docs': len(rows), 'total': sum(float(i.total or 0) for i in rows), 'error': None}
        except Exception as e:
            return {'docs': None, 'total': None, 'error': str(e), 'trace': _tb.format_exc()}

    return jsonify({
        'now': now.isoformat(),
        'month_start': month_start.isoformat(),
        'today_start': today_start.isoformat(),
        'tomorrow_start': tomorrow_start.isoformat(),
        'year_start': year_start.isoformat(),
        'today_sales': _try_summary(sale_types, today_start, tomorrow_start),
        'month_sales': _try_summary(sale_types, month_start, tomorrow_start),
        'year_sales': _try_summary(sale_types, year_start, tomorrow_start),
        'month_purchases': _try_summary(purchase_types, month_start, tomorrow_start),
    })

@reports_bp.route('/dashboard/admin', methods=['GET'])
@require_permission('reports.financial')
def get_admin_dashboard():
    """Admin dashboard aggregates for KPIs, charts, and alerts.

    Response shape (stable contract for Flutter):
      - kpis: cash_balance, gold_by_karat, gold_pure_24k, sales_today
      - series: last_7_days_sales (net_value/net_weight per day)
      - alerts: last_shift_closing (cash_diff/gold_pure_24k_diff)
    """
    from models import SafeBox, SafeBoxTransaction, Invoice, AuditLog, GoldPrice, SystemAlert

    now = datetime.now()
    today_start = datetime.combine(now.date(), datetime.min.time())
    tomorrow_start = today_start + timedelta(days=1)

    # --- Safe boxes summary (Account-derived balances; aligned with SafeBox details UI) ---
    main_karat = current_app.config.get('MAIN_KARAT', 21)
    cash_balance = 0.0
    gold_18k = 0.0
    gold_21k = 0.0
    gold_22k = 0.0
    gold_24k = 0.0

    # --- Sales today (posted only) ---
    sale_types = {
        'بيع': 1,
        'sell': 1,
        'sale': 1,
        'مرتجع بيع': -1,
    }
    today_invoices = (
        Invoice.query
        .filter(Invoice.invoice_type.in_(list(sale_types.keys())))
        .filter(Invoice.is_posted.is_(True))
        .filter(Invoice.date >= today_start)
        .filter(Invoice.date < tomorrow_start)
        .all()
    )

    sales_today_value = 0.0
    sales_today_weight = 0.0
    for inv in today_invoices:
        sign = sale_types.get(inv.invoice_type, 1)
        sales_today_value += float(inv.total or 0.0) * sign
        sales_today_weight += float(inv.total_weight or 0.0) * sign

    # --- Last 7 days sales series (posted only) ---
    start_7 = today_start - timedelta(days=6)
    series_invoices = (
        Invoice.query
        .filter(Invoice.invoice_type.in_(list(sale_types.keys())))
        .filter(Invoice.is_posted.is_(True))
        .filter(Invoice.date >= start_7)
        .filter(Invoice.date < tomorrow_start)
        .order_by(Invoice.date.asc())
        .all()
    )

    by_day = {}
    for i in range(7):
        day = (start_7 + timedelta(days=i)).date()
        key = day.isoformat()
        by_day[key] = {
            'period': key,
            'net_value': 0.0,
            'net_weight': 0.0,
            'documents': 0,
        }

    for inv in series_invoices:
        sign = sale_types.get(inv.invoice_type, 1)
        period_key = (inv.date.date() if inv.date else now.date()).isoformat()
        bucket = by_day.get(period_key)
        if bucket is None:
            continue
        bucket['documents'] += 1
        bucket['net_value'] += float(inv.total or 0.0) * sign
        bucket['net_weight'] += float(inv.total_weight or 0.0) * sign

    last_7_days_sales = list(by_day.values())

    # --- Valuation (presentation-only): pure 24k grams * raw spot per gram (24k) ---
    spot_price_24k_per_gram = None
    spot_price_timestamp = None
    try:
        latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        if latest and latest.price:
            spot_price_24k_per_gram = (float(latest.price) / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
            spot_price_timestamp = latest.date.isoformat() if latest.date else None
    except Exception:
        spot_price_24k_per_gram = None
        spot_price_timestamp = None

    inventory_value = None
    if spot_price_24k_per_gram is not None:
        try:
            inventory_value = float(gold_pure_24k) * float(spot_price_24k_per_gram)
        except Exception:
            inventory_value = None

    # --- Critical alerts (unreviewed) ---
    critical_unreviewed_count = 0
    critical_latest = None
    try:
        critical_unreviewed_count = (
            SystemAlert.query.filter(SystemAlert.severity == 'critical')
            .filter(SystemAlert.is_reviewed.is_(False))
            .count()
        )
        critical_latest = (
            SystemAlert.query.filter(SystemAlert.severity == 'critical')
            .filter(SystemAlert.is_reviewed.is_(False))
            .order_by(SystemAlert.created_at.desc())
            .first()
        )
        critical_latest = critical_latest.to_dict() if critical_latest else None
    except Exception:
        critical_unreviewed_count = 0
        critical_latest = None

    # --- Alerts: last shift closing (system-wide) ---
    last_shift_alert = None
    try:
        last_close = (
            AuditLog.query.filter_by(action='shift_closing', success=True)
            .order_by(AuditLog.timestamp.desc())
            .first()
        )
        if last_close and last_close.details:
            try:
                details = (
                    json.loads(last_close.details)
                    if isinstance(last_close.details, str)
                    else (last_close.details or {})
                )
            except Exception:
                details = {}

            cash_diff = None
            try:
                cash_diff = float(((details.get('totals') or {}).get('total_difference')))
            except Exception:
                cash_diff = None

            gold_pure_diff = None
            try:
                gold_pure_diff = float(
                    (((details.get('gold') or {}).get('pure_24k') or {}).get('difference'))
                )
            except Exception:
                gold_pure_diff = None

            last_shift_alert = {
                'entity_number': getattr(last_close, 'entity_number', None),
                'timestamp': last_close.timestamp.isoformat()
                if getattr(last_close, 'timestamp', None)
                else None,
                'user_name': getattr(last_close, 'user_name', None),
                'cash_difference': cash_diff,
                'gold_pure_24k_difference': gold_pure_diff,
            }
    except Exception:
        last_shift_alert = None

    # --- Purchases today (posted only) ---
    # Include both supplier purchases and scrap purchases from customers,
    # and include return variants used in production.
    purchase_types = {
        'شراء': 1,
        'شراء من عميل': 1,
        'مرتجع شراء': -1,
        'مرتجع شراء (مورد)': -1,
    }
    today_purchases = (
        Invoice.query
        .filter(Invoice.invoice_type.in_(list(purchase_types.keys())))
        .filter(Invoice.is_posted.is_(True))
        .filter(Invoice.date >= today_start)
        .filter(Invoice.date < tomorrow_start)
        .all()
    )

    purchases_today_value = 0.0
    purchases_today_weight = 0.0
    for inv in today_purchases:
        sign = purchase_types.get(inv.invoice_type, 1)
        purchases_today_value += float(inv.total or 0.0) * sign
        purchases_today_weight += float(inv.total_weight or 0.0) * sign

    # --- Last 7 days purchases series (posted only) ---
    purchases_series = (
        Invoice.query
        .filter(Invoice.invoice_type.in_(list(purchase_types.keys())))
        .filter(Invoice.is_posted.is_(True))
        .filter(Invoice.date >= start_7)
        .filter(Invoice.date < tomorrow_start)
        .order_by(Invoice.date.asc())
        .all()
    )

    purchases_by_day = {}
    for i in range(7):
        day = (start_7 + timedelta(days=i)).date()
        key = day.isoformat()
        purchases_by_day[key] = {
            'period': key,
            'net_value': 0.0,
            'net_weight': 0.0,
            'documents': 0,
        }

    for inv in purchases_series:
        sign = purchase_types.get(inv.invoice_type, 1)
        period_key = (inv.date.date() if inv.date else now.date()).isoformat()
        bucket = purchases_by_day.get(period_key)
        if bucket is None:
            continue
        bucket['documents'] += 1
        bucket['net_value'] += float(inv.total or 0.0) * sign
        bucket['net_weight'] += float(inv.total_weight or 0.0) * sign

    last_7_days_purchases = list(purchases_by_day.values())

    # --- Gold equivalent in main karat (from account-derived balances) ---
    gold_equivalent_main_karat = 0.0
    try:
        mk = float(main_karat or 21)
        if mk <= 0:
            mk = 21.0
        gold_equivalent_main_karat = (
            (gold_18k * (18.0 / mk))
            + gold_21k
            + (gold_22k * (22.0 / mk))
            + (gold_24k * (24.0 / mk))
        )
    except Exception:
        gold_equivalent_main_karat = 0.0

    # --- Price Intelligence: Average cost vs market price ---
    from models import Item
    avg_cost_per_gram = None
    try:
        # Calculate weighted average cost from inventory items
        items_with_cost = (
            Item.query
            .filter(Item.is_active.is_(True))
            .filter(Item.weight > 0)
            .all()
        )
        total_cost = 0.0
        total_weight_for_cost = 0.0
        for item in items_with_cost:
            item_weight = float(item.weight or 0.0)
            item_karat = int(item.karat or 21)
            # Convert to 24k equivalent for fair comparison
            weight_24k = item_weight * (item_karat / 24.0)
            # Use purchase price or calculate from gold price
            item_cost = float(item.purchase_price or 0.0)
            if item_cost > 0 and item_weight > 0:
                total_cost += item_cost
                total_weight_for_cost += weight_24k
        
        if total_weight_for_cost > 0:
            avg_cost_per_gram = total_cost / total_weight_for_cost
    except Exception:
        avg_cost_per_gram = None

    # Calculate profit margin
    profit_margin = None
    if avg_cost_per_gram and spot_price_24k_per_gram and avg_cost_per_gram > 0:
        profit_margin = ((spot_price_24k_per_gram - avg_cost_per_gram) / avg_cost_per_gram) * 100

    # --- Liquidity Coverage (7 days) ---
    from models import Customer
    payables_due_7_days = 0.0
    receivables_due_7_days = 0.0
    try:
        # Get suppliers with credit balances (we owe them)
        suppliers = Customer.query.filter(Customer.customer_type == 'مورد').all()
        for supplier in suppliers:
            balance = float(supplier.balance_cash or 0)
            if balance < 0:
                payables_due_7_days += abs(balance)

        # Get customers with debit balances (they owe us)
        customers = Customer.query.filter(Customer.customer_type == 'عميل').all()
        for customer in customers:
            balance = float(customer.balance_cash or 0)
            if balance > 0:
                receivables_due_7_days += balance
    except Exception:
        payables_due_7_days = 0.0
        receivables_due_7_days = 0.0

    liquidity_coverage_ratio = None
    if payables_due_7_days > 0:
        liquidity_coverage_ratio = (cash_balance / payables_due_7_days) * 100

    # --- Safe boxes summary ---
    # مصدر الرصيد الرسمي الوحيد: safe_box_balances_bulk (دفتر الأستاذ مباشرة)
    # -- نفس الدالة التي تستخدمها /safe-boxes/balances و/safe-boxes/<id>/balance،
    # فلا يبقى أي مكان يحسب رصيد خزينة بمنطق مستقل خاص به.
    safe_boxes_summary = []
    try:
        safe_boxes = SafeBox.query.filter(SafeBox.is_active.is_(True)).all()
        balances_by_id = safe_box_balances_bulk(safe_boxes, main_karat=main_karat)
        for sb in safe_boxes:
            bal = balances_by_id.get(sb.id) or {
                'cash': 0.0,
                'weight': {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0, 'total': 0.0},
            }
            weight = bal['weight']
            safe_boxes_summary.append({
                'id': sb.id,
                'name': sb.name,
                'safe_type': sb.safe_type,
                'balance_cash': bal['cash'],
                # Keep legacy single-field gold balance used by older UI.
                'balance_gold_21k': weight.get('21k', 0.0),
                # New: detailed weights per karat (ledger-based) for richer UI.
                'weight_balance': {k: v for k, v in weight.items() if k != 'total'},
                'total_weight_main_karat': weight.get('total', 0.0),
                'main_karat': int(main_karat or 21),
            })
    except Exception:
        safe_boxes_summary = []

    # Roll up account-derived totals for KPIs and liquidity.
    try:
        cash_balance = 0.0
        gold_18k = gold_21k = gold_22k = gold_24k = 0.0
        for sb in safe_boxes_summary:
            st = (sb.get('safe_type') or '').strip()
            if st in ('cash', 'bank', 'check'):
                cash_balance += float(sb.get('balance_cash') or 0.0)
            if st == 'gold':
                wb = sb.get('weight_balance') if isinstance(sb.get('weight_balance'), dict) else {}
                gold_18k += float(wb.get('18k') or 0.0)
                gold_21k += float(wb.get('21k') or 0.0)
                gold_22k += float(wb.get('22k') or 0.0)
                gold_24k += float(wb.get('24k') or 0.0)
    except Exception:
        cash_balance = 0.0
        gold_18k = gold_21k = gold_22k = gold_24k = 0.0

    gold_pure_24k = (
        (gold_18k * (18.0 / 24.0))
        + (gold_21k * (21.0 / 24.0))
        + (gold_22k * (22.0 / 24.0))
        + gold_24k
    )

    try:
        mk = float(main_karat or 21)
        if mk <= 0:
            mk = 21.0
        gold_equivalent_main_karat = (
            (gold_18k * (18.0 / mk))
            + gold_21k
            + (gold_22k * (22.0 / mk))
            + (gold_24k * (24.0 / mk))
        )
    except Exception:
        gold_equivalent_main_karat = 0.0

    # --- Unposted invoices count ---
    unposted_invoices_count = 0
    try:
        unposted_invoices_count = Invoice.query.filter(Invoice.is_posted.is_(False)).count()
    except Exception:
        unposted_invoices_count = 0

    # --- Yesterday comparison ---
    yesterday_start = today_start - timedelta(days=1)
    yesterday_sales_value = 0.0
    yesterday_purchases_value = 0.0
    yesterday_sales_weight = 0.0
    yesterday_purchases_weight = 0.0
    try:
        yesterday_sales = (
            Invoice.query
            .filter(Invoice.invoice_type.in_(list(sale_types.keys())))
            .filter(Invoice.is_posted.is_(True))
            .filter(Invoice.date >= yesterday_start)
            .filter(Invoice.date < today_start)
            .all()
        )
        for inv in yesterday_sales:
            sign = sale_types.get(inv.invoice_type, 1)
            yesterday_sales_value += float(inv.total or 0.0) * sign
            yesterday_sales_weight += float(inv.total_weight or 0.0) * sign
        
        yesterday_purchases = (
            Invoice.query
            .filter(Invoice.invoice_type.in_(list(purchase_types.keys())))
            .filter(Invoice.is_posted.is_(True))
            .filter(Invoice.date >= yesterday_start)
            .filter(Invoice.date < today_start)
            .all()
        )
        for inv in yesterday_purchases:
            sign = purchase_types.get(inv.invoice_type, 1)
            yesterday_purchases_value += float(inv.total or 0.0) * sign
            yesterday_purchases_weight += float(inv.total_weight or 0.0) * sign
    except Exception:
        yesterday_sales_value = 0.0
        yesterday_purchases_value = 0.0
        yesterday_sales_weight = 0.0
        yesterday_purchases_weight = 0.0

    # Calculate change percentages
    sales_change_pct = None
    if yesterday_sales_value > 0:
        sales_change_pct = ((sales_today_value - yesterday_sales_value) / yesterday_sales_value) * 100
    
    purchases_change_pct = None
    if yesterday_purchases_value > 0:
        purchases_change_pct = ((purchases_today_value - yesterday_purchases_value) / yesterday_purchases_value) * 100

    # Weight-based change percentages (preferred for this POS)
    sales_change_pct_weight = None
    if abs(yesterday_sales_weight) > 0:
        sales_change_pct_weight = ((sales_today_weight - yesterday_sales_weight) / yesterday_sales_weight) * 100

    purchases_change_pct_weight = None
    if abs(yesterday_purchases_weight) > 0:
        purchases_change_pct_weight = ((purchases_today_weight - yesterday_purchases_weight) / yesterday_purchases_weight) * 100

    # --- Net Financial Position (Cash + Gold Value) ---
    net_financial_position = cash_balance
    if spot_price_24k_per_gram and spot_price_24k_per_gram > 0:
        net_financial_position += gold_pure_24k * spot_price_24k_per_gram

    # --- Today's Profit Margin (Sales - Purchases) ---
    today_profit = sales_today_value - purchases_today_value
    today_profit_margin_pct = None
    if sales_today_value > 0:
        today_profit_margin_pct = (today_profit / sales_today_value) * 100

    # --- Yesterday Profit (for trend comparison) ---
    yesterday_profit = yesterday_sales_value - yesterday_purchases_value
    today_profit_vs_yesterday_pct = None
    if abs(yesterday_profit) > 0.01:
        today_profit_vs_yesterday_pct = ((today_profit - yesterday_profit) / abs(yesterday_profit)) * 100

    # --- Gold Price Change from Yesterday ---
    gold_price_change_pct = None
    try:
        yesterday_price = (
            GoldPrice.query
            .filter(GoldPrice.date < now.date())
            .order_by(GoldPrice.date.desc())
            .first()
        )
        if yesterday_price and yesterday_price.price and spot_price_24k_per_gram:
            yesterday_spot = (float(yesterday_price.price) / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
            if yesterday_spot > 0:
                gold_price_change_pct = ((spot_price_24k_per_gram - yesterday_spot) / yesterday_spot) * 100
    except Exception:
        gold_price_change_pct = None

    # --- Safe boxes with activity pulse (last 15 minutes) ---
    fifteen_mins_ago = now - timedelta(minutes=15)
    safe_boxes_enhanced = []
    try:
        for sb_data in safe_boxes_summary:
            sb_id = sb_data['id']
            # Check for recent activity
            recent_activity = (
                SafeBoxTransaction.query
                .filter(SafeBoxTransaction.safe_box_id == sb_id)
                .filter(SafeBoxTransaction.created_at >= fifteen_mins_ago)
                .first()
            )
            sb_data['has_recent_activity'] = recent_activity is not None
            safe_boxes_enhanced.append(sb_data)
    except Exception:
        safe_boxes_enhanced = safe_boxes_summary

    # --- Sensitive Operations (Last 5 important actions) ---
    sensitive_operations = []
    try:
        noise_actions = {
            'login_success', 'login_failed', 'logout',
            'forgot_password', 'forgot_username', 'password_reset_confirm',
        }

        recent_logs = (
            AuditLog.query
            .filter(AuditLog.success.is_(True))
            .filter(~AuditLog.action.in_(list(noise_actions)))
            .order_by(AuditLog.timestamp.desc())
            .limit(8)
            .all()
        )
        for log in recent_logs:
            op_desc = {
                # Shift closing
                'shift_closing': 'إغلاق وردية',
                # Posting/unposting
                'post_invoice': 'ترحيل فاتورة',
                'post': 'ترحيل',
                'post_batch': 'ترحيل دفعة',
                'unpost': 'إلغاء ترحيل',
                # Vouchers
                'approve_voucher': 'ترحيل سند',
                'cancel_voucher': 'إلغاء سند',
                'voucher_approve': 'اعتماد سند',
                'voucher_reject': 'رفض سند',
                'voucher_unapprove': 'إلغاء اعتماد سند',
                'batch_voucher_approve': 'اعتماد دفعة سندات',
                # Safety/ops
                'delete_voucher': 'حذف سند',
                'large_discount': 'خصم كبير',
                'create_invoice': 'إنشاء فاتورة',
            }.get(log.action, log.action)
            
            sensitive_operations.append({
                'action': log.action,
                'description': op_desc,
                'user_name': getattr(log, 'user_name', None) or 'غير معروف',
                'entity_type': getattr(log, 'entity_type', None),
                'entity_number': getattr(log, 'entity_number', None),
                'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                'time_ago': _time_ago(log.timestamp, now) if log.timestamp else None,
            })
    except Exception:
        sensitive_operations = []

    # --- Critical Alert Bar (compact) ---
    critical_bar = []
    try:
        # 0) Count of unreviewed critical alerts (even if latest message missing)
        try:
            ccount = int(critical_unreviewed_count or 0)
        except Exception:
            ccount = 0

        if ccount > 0:
            critical_bar.append({
                'severity': 'critical',
                'message_ar': f"{ccount} تنبيهات حرجة بانتظار المراجعة",
                'message_en': f"{ccount} critical alerts pending review",
                'entity_type': 'SystemAlert',
                'entity_number': None,
            })

        # 1) Latest unreviewed critical system alert
        if isinstance(critical_latest, dict):
            msg = (critical_latest.get('message') or critical_latest.get('title') or '').strip()
            if msg:
                critical_bar.append({
                    'severity': 'critical',
                    'message_ar': msg,
                    'message_en': msg,
                    'entity_type': critical_latest.get('entity_type'),
                    'entity_number': critical_latest.get('entity_number'),
                })

        # 2) Shift closing diffs (when present)
        if isinstance(last_shift_alert, dict):
            cash_diff = last_shift_alert.get('cash_difference')
            gold_diff = last_shift_alert.get('gold_pure_24k_difference')
            entity_num = last_shift_alert.get('entity_number')
            try:
                cash_diff_f = float(cash_diff) if cash_diff is not None else 0.0
            except Exception:
                cash_diff_f = 0.0
            try:
                gold_diff_f = float(gold_diff) if gold_diff is not None else 0.0
            except Exception:
                gold_diff_f = 0.0

            if abs(gold_diff_f) > 0.001:
                critical_bar.append({
                    'severity': 'warning',
                    'message_ar': f"⚠️ يوجد فرق وزني (+/-{gold_diff_f:.3f} جم 24K) في إغلاق {entity_num or ''}".strip(),
                    'message_en': f"Weight difference ({gold_diff_f:+.3f} g 24K) in shift closing {entity_num or ''}".strip(),
                    'entity_type': 'ShiftClosing',
                    'entity_number': entity_num,
                })

            if abs(cash_diff_f) > 0.01:
                critical_bar.append({
                    'severity': 'warning',
                    'message_ar': f"⚠️ يوجد فرق نقدي ({cash_diff_f:+.2f}) في إغلاق {entity_num or ''}".strip(),
                    'message_en': f"Cash difference ({cash_diff_f:+.2f}) in shift closing {entity_num or ''}".strip(),
                    'entity_type': 'ShiftClosing',
                    'entity_number': entity_num,
                })

        # 3) Low bank balance (optional threshold)
        threshold = None
        try:
            raw_thr = os.getenv('BANK_LOW_BALANCE_THRESHOLD', '').strip()
            if raw_thr:
                threshold = float(raw_thr)
        except Exception:
            threshold = None

        if threshold is not None:
            for sb in safe_boxes_enhanced:
                if (sb.get('safe_type') or '') != 'bank':
                    continue
                try:
                    bal = float(sb.get('balance_cash') or 0.0)
                except Exception:
                    bal = 0.0
                if bal < threshold:
                    name = sb.get('name') or 'Bank'
                    critical_bar.append({
                        'severity': 'warning',
                        'message_ar': f"⚠️ رصيد {name} تحت الحد المسموح ({bal:.2f} < {threshold:.2f})",
                        'message_en': f"{name} balance below threshold ({bal:.2f} < {threshold:.2f})",
                        'entity_type': 'SafeBox',
                        'entity_number': None,
                    })

        # 4) Unposted invoices
        try:
            up = int(unposted_invoices_count or 0)
        except Exception:
            up = 0
        if up > 0:
            critical_bar.append({
                'severity': 'warning',
                'message_ar': f"⚠️ {up} فاتورة بانتظار الترحيل",
                'message_en': f"{up} invoices pending posting",
                'entity_type': 'Invoice',
                'entity_number': None,
            })
    except Exception:
        critical_bar = []

    # --- Liquidity breakdown (Cash vs Banks) ---
    cash_in_hand = 0.0
    cash_in_banks = 0.0
    try:
        for sb_data in safe_boxes_enhanced:
            if sb_data['safe_type'] == 'cash':
                cash_in_hand += sb_data['balance_cash']
            elif sb_data['safe_type'] == 'bank':
                cash_in_banks += sb_data['balance_cash']
    except Exception:
        pass

    # --- Sales / Purchases / Expenses Summary (today / this month / this year) ---
    sales_purchases_summary = {}
    try:
        from models import JournalEntryLine as JELine, JournalEntry as JE2, Account as AccModel

        month_start = datetime(now.year, now.month, 1)
        year_start = datetime(now.year, 1, 1)

        _summary_periods = {
            'today': (today_start, tomorrow_start),
            'month': (month_start, tomorrow_start),
            'year': (year_start, tomorrow_start),
        }

        _EMPTY_INV_SUMMARY = {
            'total_value': 0.0, 'total_weight': 0.0, 'docs': 0,
            'by_user': [], 'by_karat': [],
        }

        # Pre-load AppUser list once; avoids a full-table scan on every _build_inv_summary call.
        _cached_app_users = []
        try:
            from models import AppUser
            _cached_app_users = AppUser.query.all()
        except Exception:
            pass

        def _build_inv_summary(inv_types_dict, start, end, exclude_gold_type=None):
            # Uses Invoice.query directly (same proven pattern as today_invoices/series_invoices).
            try:
                inv_types = [str(t).strip() for t in inv_types_dict.keys() if str(t).strip()]
                if not inv_types:
                    return dict(_EMPTY_INV_SUMMARY)

                q = (
                    Invoice.query
                    .filter(Invoice.invoice_type.in_(inv_types))
                    .filter(Invoice.is_posted.is_(True))
                    .filter(Invoice.date >= start)
                    .filter(Invoice.date < end)
                )

                if exclude_gold_type:
                    try:
                        if _db_has_column('invoice', 'gold_type'):
                            q = q.filter(
                                or_(Invoice.gold_type.is_(None), Invoice.gold_type != exclude_gold_type)
                            )
                    except Exception:
                        pass

                rows = q.all()
                if not rows:
                    return dict(_EMPTY_INV_SUMMARY)

                total_value = 0.0
                total_weight = 0.0
                by_user = {}
                by_karat = {}
                sign_by_id = {}
                employee_ids = set()
                posted_keys = set()

                for inv in rows:
                    sign = float(inv_types_dict.get(inv.invoice_type, 1) or 1)
                    sign_by_id[inv.id] = sign
                    total_value += float(inv.total or 0) * sign
                    total_weight += float(inv.total_weight or 0) * sign
                    if inv.employee_id:
                        try:
                            employee_ids.add(int(inv.employee_id))
                        except Exception:
                            pass
                    posted_raw = str(inv.posted_by or '').strip().lower()
                    if posted_raw:
                        posted_keys.add(posted_raw)

                # Resolve display name: employee name > posted_by username fallback
                employee_name_by_id = {}
                if employee_ids:
                    try:
                        for emp in Employee.query.filter(Employee.id.in_(list(employee_ids))).all():
                            if emp.name:
                                employee_name_by_id[emp.id] = emp.name
                    except Exception:
                        pass

                posted_by_to_name = {}
                if posted_keys:
                    try:
                        for u in _cached_app_users:
                            if not u.employee_id:
                                continue
                            emp_name = employee_name_by_id.get(u.employee_id, '')
                            if not emp_name:
                                continue
                            uk = str(u.username or '').strip().lower()
                            if uk and uk in posted_keys:
                                posted_by_to_name[uk] = emp_name
                            fk = str(u.full_name or '').strip().lower()
                            if fk and fk in posted_keys and fk not in posted_by_to_name:
                                posted_by_to_name[fk] = emp_name
                    except Exception:
                        pass

                for inv in rows:
                    sign = float(sign_by_id.get(inv.id, 1) or 1)
                    v = float(inv.total or 0) * sign
                    w = float(inv.total_weight or 0) * sign
                    if inv.employee_id and inv.employee_id in employee_name_by_id:
                        user = employee_name_by_id[inv.employee_id]
                    else:
                        pk = str(inv.posted_by or '').strip().lower()
                        user = posted_by_to_name.get(pk) or str(inv.posted_by or 'غير معروف').strip() or 'غير معروف'
                    if user not in by_user:
                        by_user[user] = {'value': 0.0, 'weight': 0.0, 'docs': 0}
                    by_user[user]['value'] += v
                    by_user[user]['weight'] += w
                    by_user[user]['docs'] += 1

                # Karat breakdown via InvoiceItem
                try:
                    inv_ids = [inv.id for inv in rows]
                    for item in InvoiceItem.query.filter(InvoiceItem.invoice_id.in_(inv_ids)).all():
                        sign = float(sign_by_id.get(item.invoice_id, 1) or 1)
                        try:
                            k = f"{int(float(item.karat))}k" if item.karat not in (None, '') else '?'
                        except Exception:
                            k = '?'
                        if k not in by_karat:
                            by_karat[k] = {'weight': 0.0, 'value': 0.0}
                        by_karat[k]['weight'] += float(item.weight or 0) * sign
                        by_karat[k]['value'] += float(item.net or 0) * sign
                except Exception:
                    pass

                return {
                    'total_value': round(total_value, 2),
                    'total_weight': round(total_weight, 3),
                    'docs': len(rows),
                    'by_user': sorted(
                        [{'user': u, 'value': round(d['value'], 2), 'weight': round(d['weight'], 3), 'docs': d['docs']} for u, d in by_user.items()],
                        key=lambda x: -x['value']
                    ),
                    'by_karat': sorted(
                        [{'karat': k, 'weight': round(d['weight'], 3), 'value': round(d['value'], 2)} for k, d in by_karat.items() if d['weight'] != 0],
                        key=lambda x: -(x['weight'] or 0)
                    ),
                }
            except Exception as _inv_err:
                import traceback
                print(f'[dashboard] _build_inv_summary error: {_inv_err}')
                traceback.print_exc()
                return dict(_EMPTY_INV_SUMMARY)

        def _build_expenses_summary(start, end):
            try:
                exp_total = 0.0
                exp_by_account: dict = {}
                exp_rows = (
                    db.session.query(JELine, AccModel)
                    .join(AccModel, JELine.account_id == AccModel.id)
                    .join(JE2, JELine.journal_entry_id == JE2.id)
                    .filter(AccModel.account_number.like('5%'))
                    .filter(JE2.is_posted.is_(True))
                    .filter(JE2.date >= start)
                    .filter(JE2.date < end)
                    .all()
                )
                for line, acc in exp_rows:
                    amt = float(line.cash_debit or 0)
                    exp_total += amt
                    name = (acc.name or acc.account_number or '?').strip()
                    exp_by_account[name] = exp_by_account.get(name, 0.0) + amt
                return {
                    'total_value': round(exp_total, 2),
                    'by_account': sorted(
                        [{'account': a, 'value': round(v, 2)} for a, v in exp_by_account.items() if v > 0],
                        key=lambda x: -x['value']
                    ),
                }
            except Exception:
                return {'total_value': 0.0, 'by_account': []}

        def _build_scrap_summary(start, end):
            """مشتريات الكسر والتسكير فقط (gold_type='scrap')."""
            try:
                scrap_inv_types = {'شراء من عميل': 1, 'شراء': 1, 'مرتجع شراء': -1}
                invs = (
                    Invoice.query
                    .filter(Invoice.invoice_type.in_(list(scrap_inv_types.keys())))
                    .filter(Invoice.gold_type == 'scrap')
                    .filter(Invoice.is_posted.is_(True))
                    .filter(Invoice.date >= start)
                    .filter(Invoice.date < end)
                    .all()
                )
                total_value = 0.0
                total_weight = 0.0
                for inv in invs:
                    sign = scrap_inv_types.get(inv.invoice_type, 1)
                    total_value += float(inv.total or 0) * sign
                    total_weight += float(inv.total_weight or 0) * sign
                # Current scrap moving average
                from models import InventoryCostingConfig as ICC
                scrap_cfg = ICC.query.filter_by(costing_type='scrap').first()
                avg_rate = float(scrap_cfg.avg_total_cost_per_gram or 0.0) if scrap_cfg else 0.0
                avg_gold = float(scrap_cfg.avg_gold_price_per_gram or 0.0) if scrap_cfg else 0.0
                cum_weight = float(scrap_cfg.total_inventory_weight or 0.0) if scrap_cfg else 0.0
                return {
                    'total_value': round(total_value, 2),
                    'total_weight': round(total_weight, 3),
                    'docs': len(invs),
                    'avg_rate': round(avg_rate, 4),
                    'avg_gold': round(avg_gold, 4),
                    'cumulative_weight': round(cum_weight, 3),
                }
            except Exception:
                return {'total_value': 0.0, 'total_weight': 0.0, 'docs': 0, 'avg_rate': 0.0, 'avg_gold': 0.0, 'cumulative_weight': 0.0}

        for period_key, (p_start, p_end) in _summary_periods.items():
            try:
                sales_purchases_summary[period_key] = {
                    'sales': _build_inv_summary(sale_types, p_start, p_end),
                    # Exclude scrap invoices to avoid double-counting:
                    # scrap is tracked separately in scrap_purchases.
                    'purchases': _build_inv_summary(purchase_types, p_start, p_end, exclude_gold_type='scrap'),
                    'expenses': _build_expenses_summary(p_start, p_end),
                    'scrap_purchases': _build_scrap_summary(p_start, p_end),
                }
            except Exception as _period_err:
                import traceback
                print(f'[dashboard] sales_purchases_summary period={period_key} error: {_period_err}')
                traceback.print_exc()
                sales_purchases_summary[period_key] = {}
    except Exception as _summary_err:
        import traceback
        print(f'[dashboard] sales_purchases_summary outer error: {_summary_err}')
        traceback.print_exc()
        sales_purchases_summary = {}

    return jsonify({
        'success': True,
        'generated_at': now.isoformat(),
        'global_snapshot': {
            'net_financial_position': round(net_financial_position, 2),
            'gold_price_24k': round(float(spot_price_24k_per_gram), 2) if spot_price_24k_per_gram else None,
            'gold_price_change_pct': round(gold_price_change_pct, 2) if gold_price_change_pct is not None else None,
            'gold_price_timestamp': spot_price_timestamp,
        },
        'kpis': {
            'cash_balance': round(cash_balance, 2),
            'gold_by_karat': {
                '18k': round(gold_18k, 3),
                '21k': round(gold_21k, 3),
                '22k': round(gold_22k, 3),
                '24k': round(gold_24k, 3),
            },
            'gold_pure_24k': round(gold_pure_24k, 3),
            'gold_equivalent_main_karat': round(gold_equivalent_main_karat, 3),
            'main_karat': main_karat,
            'sales_today': {
                'net_value': round(sales_today_value, 2),
                'net_weight': round(sales_today_weight, 3),
                'documents': len(today_invoices),
                'change_pct': round(sales_change_pct, 1) if sales_change_pct is not None else None,
                'change_pct_weight': round(sales_change_pct_weight, 1)
                if sales_change_pct_weight is not None
                else None,
            },
            'purchases_today': {
                'net_value': round(purchases_today_value, 2),
                'net_weight': round(purchases_today_weight, 3),
                'documents': len(today_purchases),
                'change_pct': round(purchases_change_pct, 1) if purchases_change_pct is not None else None,
                'change_pct_weight': round(purchases_change_pct_weight, 1)
                if purchases_change_pct_weight is not None
                else None,
            },
            'today_profit': round(today_profit, 2),
            'today_profit_margin_pct': round(today_profit_margin_pct, 1) if today_profit_margin_pct is not None else None,
            'yesterday_profit': round(yesterday_profit, 2),
            'today_profit_vs_yesterday_pct': round(today_profit_vs_yesterday_pct, 1) if today_profit_vs_yesterday_pct is not None else None,
        },
        'series': {
            'last_7_days_sales': [
                {
                    'period': row['period'],
                    'documents': int(row.get('documents') or 0),
                    'net_value': round(float(row.get('net_value') or 0.0), 2),
                    'net_weight': round(float(row.get('net_weight') or 0.0), 3),
                }
                for row in last_7_days_sales
            ],
            'last_7_days_purchases': [
                {
                    'period': row['period'],
                    'documents': int(row.get('documents') or 0),
                    'net_value': round(float(row.get('net_value') or 0.0), 2),
                    'net_weight': round(float(row.get('net_weight') or 0.0), 3),
                }
                for row in last_7_days_purchases
            ],
        },
        'alerts': {
            'last_shift_closing': last_shift_alert,
            'critical_unreviewed_count': int(critical_unreviewed_count or 0),
            'critical_unreviewed_latest': critical_latest,
            'unposted_invoices_count': unposted_invoices_count,
            'critical_bar': critical_bar[:3],
        },
        'valuation': {
            'spot_price_24k_per_gram': round(float(spot_price_24k_per_gram), 2)
            if spot_price_24k_per_gram is not None
            else None,
            'spot_price_timestamp': spot_price_timestamp,
            'currency': 'ر.س',
            'inventory_value': round(float(inventory_value), 2) if inventory_value is not None else None,
            'avg_cost_per_gram': round(float(avg_cost_per_gram), 2) if avg_cost_per_gram else None,
            'profit_margin_pct': round(float(profit_margin), 2) if profit_margin is not None else None,
        },
        'liquidity': {
            'cash_available': round(cash_balance, 2),
            'cash_in_hand': round(cash_in_hand, 2),
            'cash_in_banks': round(cash_in_banks, 2),
            'receivables': round(receivables_due_7_days, 2),
            'payables_due_7_days': round(payables_due_7_days, 2),
            'receivables_due_7_days': round(receivables_due_7_days, 2),
            'coverage_ratio_pct': round(liquidity_coverage_ratio, 1) if liquidity_coverage_ratio is not None else None,
        },
        'safe_boxes': safe_boxes_enhanced,
        'sensitive_operations': sensitive_operations,
        'sales_purchases_summary': sales_purchases_summary,
    }), 200

@reports_bp.route('/reports/gold_acquisition_reconciliation', methods=['GET'])
@require_permission('reports.financial')
def get_gold_acquisition_reconciliation():
    """
    شراء الذهب الشهري — تسوية نظام الفواتير مقابل القيود المحاسبية.

    Q1 (بسط avg_buy):  customer_purchases + settlement_purchases − customer_buy_returns
    Q2 — مسارَان:
      A (مرتبط بفواتير):  sum(cash_credit − cash_debit) لقيود تشير إلى فواتير Q1
      B (قائم على حسابات): قيود في الفترة تُدين حسابات ذهب (tracks_weight) لكنها خارج نطاق A
      → يكشف: سند صرف مباشر، قيد يدوي، أو فاتورة مصنّفة خطأً

    التباين = Q2(A+B) − Q1
      إيجابي → نقدية خرجت لاقتناء ذهب خارج مسار avg_buy (فاتورة ناقصة أو قيد يدوي)
      سالب   → فواتير بلا قيود مُرحَّلة
      صفر    → النظامان متسقان
    """
    try:
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')

        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد start_date و end_date'}), 400

        start_dt = datetime.strptime(start_date_str, '%Y-%m-%d')
        end_dt = datetime.strptime(end_date_str, '%Y-%m-%d') + timedelta(days=1)

        from services.gold_acquisition_reconciliation import compute as _reconcile
        result = _reconcile(start_dt, end_dt)

        return jsonify({
            'period': {'start': start_date_str, 'end': end_date_str},
            **result,
        }), 200

    except Exception as exc:
        return jsonify({'error': str(exc)}), 500


def _time_ago(dt, now):
    """Helper to format time ago in Arabic."""
    if not dt:
        return None
    diff = now - dt
    seconds = diff.total_seconds()
    if seconds < 60:
        return 'الآن'
    elif seconds < 3600:
        mins = int(seconds // 60)
        return f'منذ {mins} دقيقة'
    elif seconds < 86400:
        hours = int(seconds // 3600)
        return f'منذ {hours} ساعة'
    else:
        days = int(seconds // 86400)
        return f'منذ {days} يوم'

