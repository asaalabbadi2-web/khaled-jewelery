"""Reports domain routes — reports_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, timedelta

from flask import Blueprint, current_app, jsonify, request
from sqlalchemy import String, and_, case, cast, func, or_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    AccountingMapping,
    Employee,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    JournalEntry,
    JournalEntryLine,
    SafeBox,
)
from core.database import _db_has_column
from core.dates import _parse_iso_date
from auth_decorators import get_current_user, require_auth, require_permission

from pricing.karat_service import convert_to_main_karat, get_main_karat
from accounting.mappings import (DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_by_number, get_account_id_for_mapping,
                                 require_account)
from services.live_balances import live_balances_by_account_ids
from utils import normalize_number
from routes import _line_weight_total_in_main_karat

reports_bp = Blueprint('reports', __name__)

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

@reports_bp.route('/trial_balance', methods=['GET'])
@require_permission('reports.financial')
def get_trial_balance():
    """The trial balance in the reports' contract (services/reports/trial_balance.py,
    REPORTS ت0-3), with the old keys alongside until the screen reads the
    contract (ت1). start_date / end_date (YYYY-MM-DD, the end day whole),
    karat_detail, under (an account: its subtree and their twins)."""
    from services.reports.trial_balance import trial_balance
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    karat_detail = request.args.get('karat_detail', 'false').lower() == 'true'
    under = request.args.get('under', type=int)
    report = trial_balance(start=start, end=end, karat_detail=karat_detail, under=under,
                           now=datetime.now()).to_dict()
    report.update({'trial_balance': report['rows'], 'count': len(report['rows']),
                   'filters': {'start_date': report['period']['start'], 'end_date': report['period']['end'],
                               'karat_detail': karat_detail}})
    return jsonify(report)

@reports_bp.route('/reports/gold_price_history', methods=['GET'])
@require_permission('reports.financial')
def get_gold_price_history_report():
    """The gold price's history in the reports' contract (services/reports/gold_price_history.py,
    REPORTS ت5-4): start_date / end_date (Riyadh days; the last 90 if none), by (day, week, month)."""
    from pricing import price_clock
    from services.reports.gold_price_history import BY, gold_price_history
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    by = request.args.get('by', 'day')
    if by not in BY:
        return jsonify({'error': 'invalid_by', 'message': f'by: {" | ".join(BY)}'}), 400
    end = end or price_clock.riyadh_today(price_clock.utc_now())
    start = start or end - timedelta(days=90)
    if start > end:
        return jsonify({'error': 'invalid_period', 'message': 'start_date بعد end_date'}), 400
    return jsonify(gold_price_history(start=start, end=end, by=by, now=datetime.now()).to_dict())


@reports_bp.route('/reports/income_statement', methods=['GET'])
@require_permission('reports.financial')
def get_income_statement():
    """The income statement in the reports' contract -- riyals by the tree, grams
    by the gram profit's five layers (services/reports/income_statement.py,
    REPORTS ت2-2) -- with the old keys alongside until the screen moves to the
    shell. start_date and end_date (YYYY-MM-DD, the end day whole), both."""
    from services.reports.income_statement import income_statement, tree_income
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    if start is None or end is None:
        return jsonify({'error': 'يجب تحديد تاريخ البداية والنهاية'}), 400
    tree = tree_income(start, end)
    revenue = round(sum(d['amount'] for d in tree['revenue']), 2)
    cogs = round(sum(d['amount'] for d in tree['cost_of_sales']), 2)
    operating = round(sum(d['amount'] for d in tree['operating']), 2)
    gross, net = round(revenue - cogs, 2), round(revenue - cogs - operating, 2)
    wage = tree['wage']
    wage_amount = wage['amount'] if wage else 0.0
    expenses = sorted(tree['cost_of_sales'] + tree['operating'], key=lambda d: d['account_code'])
    body = income_statement(start=start, end=end, now=datetime.now()).to_dict()
    body.update({
        'start_date': start.isoformat(), 'end_date': end.isoformat(), 'report_type': 'income_statement',
        'summary': {'net_revenue': revenue, 'cost_of_sales': cogs, 'cost_basis': tree['cost_basis'],
                    'cost_basis_note': tree['cost_basis_note'], 'gross_profit': gross,
                    'operating_expenses': operating, 'operating_expenses_excl_wage': operating,
                    'manufacturing_wage_expense': round(wage_amount, 2), 'net_profit': net,
                    'net_margin_pct': round(net / revenue * 100, 2) if revenue else 0.0},
        'series': [],
        'revenues': {'details': tree['revenue'], 'total': revenue},
        'expenses': {'details': expenses, 'total': round(cogs + operating, 2)},
        'cost_of_goods_sold': {'details': tree['cost_of_sales'], 'total': cogs},
        'gross_profit': gross,
        'operating_expenses': {'details': tree['operating'], 'total': operating,
                               'manufacturing_wage': wage or {'account_code': None,
                                                              'account_name': 'مصروفات أجور المصنعية',
                                                              'amount': round(wage_amount, 2)}},
        'manufacturing_wage_expense': {'amount': round(wage_amount, 2),
                                       'account': wage['account_code'] if wage else None,
                                       'name': wage['account_name'] if wage else 'مصروفات أجور المصنعية'},
        'expense_breakdown': sorted(([wage] if wage else []) + tree['operating'],
                                    key=lambda x: abs(x.get('amount', 0)), reverse=True)[:5],
        'net_income': net,
    })
    return jsonify(body), 200

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


@reports_bp.route('/reports/cash-flow', methods=['GET'])
@require_permission('reports.financial')
def get_cash_flow():
    """The cash flow, by the direct method, in the reports' contract
    (services/reports/cash_flow.py, REPORTS ت2-3): start_date and end_date
    (YYYY-MM-DD, the end day whole), both."""
    from services.reports.cash_flow import cash_flow
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    if start is None or end is None:
        return jsonify({'error': 'period_required', 'message': 'التدفقات النقدية لفترة: start_date و end_date'}), 400
    return jsonify(cash_flow(start=start, end=end, now=datetime.now()).to_dict())


@reports_bp.route('/reports/balance-sheet', methods=['GET'])
@require_permission('reports.financial')
def get_balance_sheet():
    """The balance sheet on a day (as_of, YYYY-MM-DD, today if none) in the
    reports' contract (services/reports/balance_sheet.py, REPORTS ت2-1)."""
    from services.reports.balance_sheet import balance_sheet
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    return jsonify(balance_sheet(as_of=as_of, now=datetime.now()).to_dict())


@reports_bp.route('/reports/customer-balances', methods=['GET'])
@require_permission('reports.customers')
def get_customer_balances():
    """Customers' balances on a day (as_of, YYYY-MM-DD, today if none), in riyals and
    grams, from the ledger (services/reports/customer_balances.py, REPORTS ت5-1)."""
    from services.reports.customer_balances import customer_balances
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    return jsonify(customer_balances(as_of=as_of, now=datetime.now()).to_dict())


@reports_bp.route('/reports/gold-by-place', methods=['GET'])
@require_permission('reports.gold_position')
def get_gold_by_place():
    """The shop's gold by its place on a day (as_of, YYYY-MM-DD, today if none) in the
    reports' contract (services/reports/gold_by_place.py, REPORTS ت5-2)."""
    from services.reports.gold_by_place import gold_by_place
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    return jsonify(gold_by_place(as_of=as_of, now=datetime.now()).to_dict())


@reports_bp.route('/reports/safe-gold-reconciliation', methods=['GET'])
@require_permission('reports.financial')
def get_safe_gold_reconciliation():
    """The gold safes' statements against the books on a day (as_of, YYYY-MM-DD, today
    if none), in the reports' contract (services/reports/safe_gold_reconciliation.py,
    REPORTS ت5-3)."""
    from services.reports.safe_gold_reconciliation import safe_gold_reconciliation
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    return jsonify(safe_gold_reconciliation(as_of=as_of, now=datetime.now()).to_dict())


@reports_bp.route('/reports/payroll', methods=['GET'])
@require_permission('reports.employees')
def get_payroll_report():
    """The payroll in the reports' contract (services/reports/payroll.py, REPORTS ت6-2ب):
    start_date / end_date (the months they touch), by (month, employee, line)."""
    from services.reports.payroll import BY, payroll_report
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    by = request.args.get('by', 'month')
    if by not in BY:
        return jsonify({'error': 'invalid_by', 'message': f'by: {" | ".join(BY)}'}), 400
    if start is None or end is None or start > end:
        return jsonify({'error': 'invalid_period', 'message': 'فترة بأولها وآخرها'}), 400
    return jsonify(payroll_report(start=start, end=end, by=by, now=datetime.now()).to_dict())


@reports_bp.route('/reports/supplier-aging', methods=['GET'])
@require_permission('reports.purchases')
def get_supplier_aging():
    """The suppliers' aging on a day (as_of, YYYY-MM-DD, today if none), in riyals
    or grams (dimension: cash | gold), in the reports' contract
    (services/reports/supplier_aging.py, REPORTS ت3-2ب)."""
    from services.reports.supplier_aging import DIMENSIONS, supplier_aging
    try:
        as_of = _report_date('as_of', datetime.now().date())
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'as_of بصيغة YYYY-MM-DD'}), 400
    dimension = request.args.get('dimension', 'cash')
    if dimension not in DIMENSIONS:
        return jsonify({'error': 'invalid_dimension', 'message': f'dimension: {" | ".join(DIMENSIONS)}'}), 400
    return jsonify(supplier_aging(as_of=as_of, dimension=dimension, now=datetime.now()).to_dict())


@reports_bp.route('/reports/purchases-analysis', methods=['GET'])
@require_permission('reports.purchases')
def get_purchases_analysis():
    """Purchases analysis in the reports' contract (services/reports/purchases_analysis.py,
    REPORTS ت4-4أ): start_date / end_date (the end day whole), by (kind, party, employee,
    day, month, karat), compare (the period before)."""
    from services.reports.purchases_analysis import BY, purchases_analysis
    try:
        start, end = _report_date('start_date'), _report_date('end_date')
    except ValueError:
        return jsonify({'error': 'invalid_date', 'message': 'start_date و end_date بصيغة YYYY-MM-DD'}), 400
    by = request.args.get('by', 'kind')
    if by not in BY:
        return jsonify({'error': 'invalid_by', 'message': f'by: {" | ".join(BY)}'}), 400
    compare = request.args.get('compare', 'false').lower() == 'true'
    against_sales = request.args.get('against_sales', 'false').lower() == 'true'
    return jsonify(purchases_analysis(start=start, end=end, by=by, compare=compare, against_sales=against_sales,
                                      now=datetime.now()).to_dict())


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


