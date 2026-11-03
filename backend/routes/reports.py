"""Reports domain routes — reports_bp registered under /api in app.py."""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime, time, timedelta

from flask import Blueprint, current_app, jsonify, request
from statistics import pstdev
from sqlalchemy import String, and_, case, cast, func, or_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    AccountingMapping,
    Customer,
    Employee,
    GoldPrice,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    InvoicePayment,
    Item,
    JournalEntry,
    JournalEntryLine,
    Office,
    SafeBox,
    SafeBoxTransaction,
)
from core.database import _db_has_column
from core.dates import _parse_iso_date
from auth_decorators import get_current_user, require_auth, require_permission

from pricing.karat_service import convert_to_main_karat, get_main_karat
from accounting.mappings import (DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_by_number, get_account_id_for_mapping,
                                 require_account)
from accounting.wages import manufacturing_wage_expense_account_id
from services.live_balances import live_balances_by_account_ids
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
    Now backed by the gold safes' accounts in the ledger (BALANCE-001, ADR-051)
    -- not the SafeBoxTransaction rows, a second book that drifted from it.

    Query params:
    - start_date, end_date (YYYY-MM-DD) -> the entries' dates
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

    main_karat = float(get_main_karat())

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
        """The safe's grams from the ledger -- its account's posted lines, between
        the entries' dates when a period is given (BALANCE-001, ADR-051); the
        safe-box rows are a second book that drifted from it."""
        from accounting.balances import counted_line_filters
        from services.live_balances import live_balances_by_account_ids
        safe = SafeBox.query.get(int(safe_id)) if safe_id else None
        if safe is None or not safe.account_id:
            return {
                'weights_by_karat': {},
                'total_weight': 0.0,
                'total_weight_main_karat': 0.0,
                'first_date': None,
                'last_date': None,
            }
        live = live_balances_by_account_ids([safe.account_id], start=start_dt, end=end_dt)[int(safe.account_id)]
        w_bal = {k: float(live.get(k) or 0.0) for k in ['18k', '21k', '22k', '24k']}
        total_weight = float(sum(w_bal.values()))
        total_weight_main = 0.0
        try:
            for k, grams in w_bal.items():
                karat = float(str(k).replace('k', ''))
                total_weight_main += float(convert_to_main_karat(float(grams or 0.0), karat))
        except Exception:
            total_weight_main = 0.0
        dates = (db.session.query(func.min(JournalEntry.date), func.max(JournalEntry.date))
                 .join(JournalEntryLine, JournalEntryLine.journal_entry_id == JournalEntry.id)
                 .filter(JournalEntryLine.account_id == safe.account_id, *counted_line_filters())
                 .filter(*([JournalEntry.date >= start_dt] if start_dt else []))
                 .filter(*([JournalEntry.date < end_dt] if end_dt else []))
                 .first())
        first_dt_local, last_dt_local = (dates or (None, None))
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
        # The ledger's balance, read one way (BALANCE-001 B1/B3).
        from services.party_live_balances import compute_live_customer_balances
        live = compute_live_customer_balances(customers)
        for customer in customers:
            bal = live.get(int(customer.id)) or {}
            gold_balance_main = (
                convert_to_main_karat(bal.get('18k', 0.0), 18)
                + convert_to_main_karat(bal.get('21k', 0.0), 21)
                + convert_to_main_karat(bal.get('22k', 0.0), 22)
                + convert_to_main_karat(bal.get('24k', 0.0), 24)
            )
            balance_map[customer.id] = {
                'cash': round_money(bal.get('cash', 0.0)),
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

    main_karat = get_main_karat()

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
    main_karat = int(get_main_karat())

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
    # By the tree under the inventory group's role, and the weight twins of the
    # new, scrap and wage stock by their links (CHART-002 release 5: '13%' and
    # 71300/71310/71320 were written here).
    from accounting.chart_tree import GOLD_INVENTORY_ROOT, role_subtree_ids, twin_id
    gold_inventory_weight_ids = {t for t in (
        twin_id(require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_inventory_new')),
        twin_id(require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_inventory_scrap')),
        twin_id(require_account('شراء', 'manufacturing_wage_inventory'))) if t}
    inv_condition = or_(
        Account.id.in_(role_subtree_ids(GOLD_INVENTORY_ROOT)),
        Account.id.in_(gold_inventory_weight_ids),
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

    physical_main_expr = physical_24k_expr * (24.0 / float(main_karat))

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

    weight_out_main_sum = weight_out_24k_sum * (24.0 / float(main_karat))
    weight_in_main_sum = weight_in_24k_sum * (24.0 / float(main_karat))

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

# Accounts domain → routes/accounts.py (ledger)
# (GET /account_ledger/<id>)

@reports_bp.route('/trial_balance', methods=['GET'])
@require_permission('reports.financial')
def get_trial_balance():
    """The trial balance in the reports' contract (services/reports/trial_balance.py,
    REPORTS ت0-3), with the old keys alongside until the screen reads the
    contract (ت1). start_date / end_date (YYYY-MM-DD, the end day whole),
    karat_detail."""
    from services.reports.trial_balance import trial_balance
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    karat_detail = request.args.get('karat_detail', 'false').lower() == 'true'
    report = trial_balance(start=start, end=end, karat_detail=karat_detail, now=datetime.now()).to_dict()
    report.update({'trial_balance': report['rows'], 'count': len(report['rows']),
                   'filters': {'start_date': report['period']['start'], 'end_date': report['period']['end'],
                               'karat_detail': karat_detail}})
    return jsonify(report)

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

    # Days are Riyadh's; the stored times are UTC (pricing/price_clock.py).
    from pricing import price_clock
    now = price_clock.utc_now()
    today = price_clock.riyadh_today(now)
    default_start = today - timedelta(days=90)
    applied_start = start_value or default_start
    applied_end = end_value or today

    if applied_start > applied_end:
        return jsonify({'error': 'start_date must be before end_date'}), 400

    try:
        limit = int(limit_param) if limit_param else 180
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400
    limit = max(12, min(limit, 730))

    start_dt, _ = price_clock.riyadh_day_bounds_utc(applied_start)
    _, end_dt = price_clock.riyadh_day_bounds_utc(applied_end)

    price_rows = (
        GoldPrice.query
        .filter(GoldPrice.date >= start_dt)
        .filter(GoldPrice.date < end_dt)
        .order_by(GoldPrice.date.asc())
        .all()
    )

    # Riyals a gram are each price's own: the office's, by the terms it was
    # saved with -- by the ounce before them (OFFICE-PRICE-1).
    from pricing.office_price import row_gram_price
    main_karat = get_main_karat()

    def mean(values):
        return sum(values) / len(values) if values else 0.0

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
        timestamp = price_clock.to_riyadh(row.date or now)
        price_value = float(row.price or 0.0)
        sar_24, sar_main = row_gram_price(row, 24), row_gram_price(row, main_karat)
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
                'sar_24': [],
                'sar_main': [],
            }
            bucket_map[key] = bucket
        bucket['sar_24'].append(sar_24)
        bucket['sar_main'].append(sar_main)

        bucket['count'] += 1
        bucket['total_price'] += price_value
        bucket['min_price'] = price_value if bucket['min_price'] is None else min(bucket['min_price'], price_value)
        bucket['max_price'] = price_value if bucket['max_price'] is None else max(bucket['max_price'], price_value)
        if bucket['first_price'] is None:
            bucket['first_price'] = price_value
            bucket['first_date'] = timestamp
        bucket['last_price'] = price_value
        bucket['last_date'] = timestamp

        price_points.append({'bucket': key, 'price_usd': price_value, 'timestamp': timestamp,
                             'sar_24': sar_24, 'sar_main': sar_main})

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

    for bucket in bucket_map.values():
        avg_price = bucket['total_price'] / bucket['count'] if bucket['count'] else 0.0
        avg_sar_24 = mean(bucket['sar_24'])
        high_sar = max(bucket['sar_24']) if bucket['sar_24'] else None
        low_sar = min(bucket['sar_24']) if bucket['sar_24'] else None
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
            'avg_price_sar_main_karat': round_money(mean(bucket['sar_main'])),
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
    avg_price_sar_24 = mean([entry['sar_24'] for entry in price_series])
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
        'start_price_sar_24k': round_money(start_point['sar_24']),
        'end_price_sar_24k': round_money(end_point['sar_24']),
        'average_price_usd': round_money(avg_price_usd),
        'average_price_sar_24k': round_money(avg_price_sar_24),
        'average_price_sar_main_karat': round_money(mean([entry['sar_main'] for entry in price_series])),
        'absolute_change_usd': round_money(end_point['price_usd'] - start_point['price_usd']),
        'absolute_change_sar_24k': round_money(
            end_point['sar_24'] - start_point['sar_24']
        ),
        'percent_change': round_money(percent_change),
        'volatility_percent': round_money(volatility_percent),
        'highest_price': {
            'value_usd': round_money(highest_point['price_usd']),
            'value_sar_24k': round_money(highest_point['sar_24']),
            'timestamp': highest_point['timestamp'].isoformat(),
        },
        'lowest_price': {
            'value_usd': round_money(lowest_point['price_usd']),
            'value_sar_24k': round_money(lowest_point['sar_24']),
            'timestamp': lowest_point['timestamp'].isoformat(),
        },
        'main_karat': main_karat,
    }

    latest_price = {
        'price_usd': round_money(end_point['price_usd']),
        'price_sar_24k': round_money(end_point['sar_24']),
        'price_sar_main_karat': round_money(end_point['sar_main']),
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

    main_karat = get_main_karat()

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
    price_reference = None
    if latest_price and latest_price.price:
        # The office's price, by the terms it was saved with (OFFICE-PRICE-1).
        from pricing.office_price import row_gram_price
        per_gram_24k = round_weight(row_gram_price(latest_price, 24))
        per_gram_main = round_weight(row_gram_price(latest_price, main_karat))
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

        # The lines that count (the one definition: posted, not a draft, not
        # deleted -- it took «posted or NULL» and kept deleted lines and drafts),
        # summed per account in the database.
        from accounting.balances import counted_line_filters
        from services.income_accounts import income_account_groups
        groups = income_account_groups()
        wanted = groups['revenue'] | groups['cost_of_sales'] | groups['operating']
        sums = (
            db.session.query(JournalEntryLine.account_id,
                             func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
                             func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0))
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntry.date >= start_date, JournalEntry.date < end_date)
            .filter(*counted_line_filters())
            .filter(JournalEntryLine.account_id.in_(wanted or {-1}))
            .group_by(JournalEntryLine.account_id)
            .all()
        )
        accounts = {a.id: a for a in Account.query.filter(Account.id.in_([r[0] for r in sums] or [-1])).all()}

        def detail(account_id, amount):
            account = accounts[account_id]
            return {'account_code': account.account_number, 'account_name': account.name,
                    'account_id': account_id, 'amount': round(amount, 2)}

        revenue_details, cost_of_goods_details, operating_expense_details = [], [], []
        for account_id, debit, credit in sums:
            if account_id in groups['revenue']:
                amount = float(credit) - float(debit)
                if abs(amount) >= 0.005:
                    revenue_details.append(detail(account_id, amount))
            else:
                amount = float(debit) - float(credit)
                if abs(amount) < 0.005:
                    continue
                # By the chart tree (services/income_accounts.py): 51 and what is
                # under it is the cost of sales -- wages, scrap purchases, the cost
                # of gold sold; the rest of group 5 is operating. It classified by
                # prefixes («50», «52» as cost), and 2026's gross profit exceeded
                # its revenue (the owner, 11 Oct 2026).
                (cost_of_goods_details if account_id in groups['cost_of_sales']
                 else operating_expense_details).append(detail(account_id, amount))

        total_revenue = sum(d['amount'] for d in revenue_details)
        total_cogs = sum(d['amount'] for d in cost_of_goods_details)
        total_operating = sum(d['amount'] for d in operating_expense_details)
        expense_details = cost_of_goods_details + operating_expense_details
        total_expense = total_cogs + total_operating

        # The manufacturing wage is a cost of sales (510, under 51), shown on its own.
        manufacturing_wage_acc_id = manufacturing_wage_expense_account_id()
        manufacturing_wage_detail = next(
            (d for d in cost_of_goods_details if d['account_id'] == manufacturing_wage_acc_id), None)
        manufacturing_wage_amount = manufacturing_wage_detail['amount'] if manufacturing_wage_detail else 0.0
        operating_expenses_total = total_operating

        gross_profit = total_revenue - total_cogs
        net_income = gross_profit - operating_expenses_total
        # Which months carry the gold's cost at its moving average (ADR-042 phase 2).
        from services.gold_cost_books import cost_basis
        basis, cost_basis_note = cost_basis(start_date, end_date)

        # حساب النسب المئوية
        net_margin_pct = (net_income / total_revenue * 100) if total_revenue != 0 else 0.0
        
        return jsonify({
            'start_date': start_date_str,
            'end_date': end_date_str,
            'report_type': 'income_statement',
            'summary': {
                # المؤشرات المالية (نقدي)
                'net_revenue': round(total_revenue, 2),
                'cost_of_sales': round(total_cogs, 2),
                'cost_basis': basis,
                'cost_basis_note': cost_basis_note,
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

def _report_date(name, default=None):
    raw = request.args.get(name)
    if not raw:
        return default
    return datetime.strptime(raw, '%Y-%m-%d').date()


@reports_bp.route('/reports/sales-analysis', methods=['GET'])
@require_permission('reports.financial')
def get_sales_analysis():
    """Sales analysis in the reports' contract (services/reports/sales_analysis.py,
    REPORTS ت1-2): start_date / end_date (the end day whole), by (employee,
    customer, day, month), compare (the period before, of the same length)."""
    from services.reports.sales_analysis import BY, sales_analysis
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    by = request.args.get('by', 'employee')
    if by not in BY:
        return jsonify({'error': 'invalid_by', 'message': f'by: {" | ".join(BY)}'}), 400
    compare = request.args.get('compare', 'false').lower() == 'true'
    return jsonify(sales_analysis(start=start, end=end, by=by, compare=compare, now=datetime.now()).to_dict())


@reports_bp.route('/reports/weight-position', methods=['GET'])
@require_permission('reports.financial')
def get_weight_position():
    """«مركز التسكير»: the riyals of what was sold, waiting to become gold
    again, and what they would buy at the shop's own purchase price (ADR-048)."""
    from services.weight_position import position
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    return jsonify(position(as_of)), 200


@reports_bp.route('/reports/weight-position/summary', methods=['GET'])
@require_permission('reports.financial')
def get_weight_position_summary():
    """The manager's card: what waits, what it buys, the price's grip, the oldest
    sale's wait against the owner's alert days, and the month realized (ADR-048)."""
    from services.weight_position import summary
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    return jsonify(summary(as_of)), 200


@reports_bp.route('/reports/weight-position/sale/<int:invoice_id>', methods=['GET'])
@require_permission('reports.financial')
def get_sale_weight_closing(invoice_id):
    """One sale in the position: its riyals returned, closed (by what) and
    waiting -- what the stored order and the invoice's weight_closing_*
    fields used to answer (ADR-048 phase 3a)."""
    from services.weight_position import sale_closing
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    view = sale_closing(invoice_id, as_of)
    if view is None:
        return jsonify({'error': 'not_a_standing_sale',
                        'message': 'ليست فاتورة بيع مرحَّلة قائمة، فلا ريالات لها في التسكير'}), 404
    return jsonify(view), 200


@reports_bp.route('/reports/weight-performance', methods=['GET'])
@require_permission('reports.financial')
def get_weight_performance():
    """The weight profit of a period, in its five layers, and month by month (ADR-048)."""
    from services.weight_position import (collect_events, performance, performance_by_month,
                                          office_prices, year_start)
    try:
        end = _report_date('end_date', datetime.now().date())
        start = _report_date('start_date', end.replace(day=1))
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    if start > end:
        return jsonify({'error': 'invalid_range', 'message': 'بداية الفترة بعد نهايتها'}), 400
    # The year's books and scrap prices read once, for the period and its months.
    events = collect_events(year_start(end), datetime.combine(end, datetime.max.time()))
    prices = office_prices(end)
    return jsonify({'period': performance(start, end, events, prices),
                    'months': performance_by_month(start, end, events, prices)}), 200


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

        # A sale's VAT is not revenue (the owner, 11 Oct 2026): its total less
        # the VAT its posted entry carries -- none, and the total is all revenue.
        from services.sales_vat import posted_sales_vat
        sales_vat = posted_sales_vat([inv.id for inv in sell_invoices + sell_return_invoices])
        total_sales_cash = 0.0
        total_weight_sold = 0.0
        for inv in sell_invoices:
            total_sales_cash += float(inv.total or 0.0) - sales_vat.get(inv.id, 0.0)
            total_weight_sold += _inv_weight_in_main_karat(inv)
        for inv in sell_return_invoices:
            total_sales_cash -= float(inv.total or 0.0) - sales_vat.get(inv.id, 0.0)
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

        from services.gram_profit_accounts import gram_profit_accounts
        revenue_account_ids, expense_account_ids = gram_profit_accounts()
        flagged_accounts = (Account.query.filter(Account.id.in_(revenue_account_ids | expense_account_ids)).all()
                            if (revenue_account_ids or expense_account_ids) else [])

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
            if acc.tracks_weight:   # a weight account (74/75): its mark, not its number
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

        # ربح المتاجرة النقدي (مستقل عن avg_buy)
        gross_profit = trading_profit_cash

        # ══════════════════════════════════════════════════════════════════
        # The weight layers, from the weight position engine (ADR-048, the
        # owner 16 Oct 2026: five layers). The riyals that became gold count at
        # what they bought; the riyals still waiting at the office's price now (⑤). It was each riyal of the period at the period's
        # average buy price -- no purchases, no figure; a closing late or the
        # price moving, a wrong one. With everything turned into gold at one
        # price the two agree to the gram (tests/test_weight_position.py).
        # ══════════════════════════════════════════════════════════════════
        from services.weight_position import performance as _weight_performance
        _perf = _weight_performance(start_dt.date(), (end_dt - timedelta(days=1)).date())
        _layers = _perf['layers']
        trading_profit_weight        = _layers['trading']                       # ①
        extra_revenue_cash_as_weight = _layers['revenue_converted']             # ② (riyals)
        extra_revenue_weight         = _layers['revenue_direct']                # ② (weight lines)
        total_extra_revenue_weight   = extra_revenue_cash_as_weight + extra_revenue_weight
        total_expense_weight_direct  = -_layers['expense_direct']               # ③ (a positive cost)
        total_expense_cash_weight    = -_layers['expense_cash']                 # ④ (a positive cost)
        price_effect_weight          = _layers['price_effect']                  # ⑤
        gross_profit_weight          = trading_profit_weight
        net_profit_weight            = _perf['weight_profit']
        valuation_price              = _perf['valuation_price'] or avg_buy_per_gram
        net_profit_cash      = net_profit_weight * valuation_price if valuation_price else None
        net_margin_pct       = ((net_profit_cash / total_sales_cash * 100)
                                if net_profit_cash is not None and total_sales_cash > 0 else None)
        total_oper_expenses  = expense_cash_total + expense_weight_direct * (valuation_price or 0.0)
        unavailable_reason   = None

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

            # الطبقة ⑤ — ما لم يُسكَّر بعد (ADR-048): ربح مبيعات تنتظر بسعر بيعها، وأثر السعر منذه
            'price_effect_weight': _rn(price_effect_weight, 3),
            'price_effect_waiting_sales_weight': _perf['price_effect_parts']['waiting_sales'],
            'price_effect_price_weight': _perf['price_effect_parts']['price'],
            'realized_weight': _perf['realized'],
            'unrealized_start_weight': _perf['unrealized_start'],
            'unrealized_end_weight': _perf['unrealized_end'],
            'valuation_price_per_gram': _rn(valuation_price, 4),
            'valuation_price_source': _perf['valuation_price_source'],

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
        # The role is AccountingMapping.account_type (there is no mapping_key).
        bridge_mapping = AccountingMapping.query.filter(
            AccountingMapping.account_type.like('%bridge%')
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
            
            # The ledger's balance (BALANCE-001 B3), not the cached column.
            balance = float((live_balances_by_account_ids([account.id]).get(int(account.id)) or {}).get('cash') or 0.0)
            
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

        end_date_str = request.args.get('date')
        if end_date_str:
            end_date = datetime.fromisoformat(end_date_str).date()
        else:
            end_date = datetime.now().date()

        main_karat = get_main_karat()

        # 1) حساب أرصدة المخزون المالية 13xx
        # مجموعة المخزون، بالشجرة تحت دورها (CHART-002)
        from accounting.chart_tree import GOLD_INVENTORY_ROOT, role_subtree_ids, subtree_ids, twin_id
        financial_accounts = Account.query.filter(
            Account.id.in_(role_subtree_ids(GOLD_INVENTORY_ROOT)),
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
        # فرع توأم مخزون الكسر المربوط (لا البادئة 7131 — CHART-002)
        _scrap_twin = twin_id(require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_inventory_scrap'))
        gold_accounts = Account.query.filter(
            Account.id.in_(subtree_ids(_scrap_twin) if _scrap_twin else set()),
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
            expected_gold_number = number
            if fin is not None:
                # نظير الحساب المالي الوزني: توأمه المربوط (لا «7 + الرقم» — CHART-002)
                _twin = db.session.get(Account, fin['account'].memo_account_id) if fin['account'].memo_account_id else None
                expected_gold_number = _twin.account_number if _twin is not None else None

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

        end_date_str = request.args.get('date')
        if end_date_str:
            end_date = datetime.fromisoformat(end_date_str).date()
        else:
            end_date = datetime.now().date()

        main_karat = float(get_main_karat())
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
        
        start_date_str = request.args.get('start_date')
        end_date_str = request.args.get('end_date')
        
        if not start_date_str or not end_date_str:
            return jsonify({'error': 'يجب تحديد تاريخ البداية والنهاية'}), 400
        
        start_date = datetime.fromisoformat(start_date_str).date()
        end_date = datetime.fromisoformat(end_date_str).date()
        main_karat = get_main_karat()
        
        # جلب حسابات الإيرادات (74xx) من شجرة المذكرة
        from accounting.chart_tree import EXPENSES_ROOT, REVENUE_ROOT, twin_subtree_ids
        # توأما مجموعتي الإيرادات والمصروفات المربوطان (74، 75)، بالشجرة (CHART-002)
        revenue_accounts = Account.query.filter(
            Account.transaction_type == 'gold',
            Account.id.in_(twin_subtree_ids(REVENUE_ROOT))
        ).all()
        
        # جلب حسابات المصروفات (75xx) من شجرة المذكرة
        expense_accounts = Account.query.filter(
            Account.transaction_type == 'gold',
            Account.id.in_(twin_subtree_ids(EXPENSES_ROOT))
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


