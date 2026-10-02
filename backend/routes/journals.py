"""Journal-entries domain routes — journals_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, timedelta

from flask import Blueprint, g, jsonify, request
from services.approval_policy import actor, may_approve_own
from sqlalchemy import String, and_, cast, func, or_
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    SafeBox,
    SafeBoxTransaction,
    Voucher,
)

from core.database import _db_has_column
from core.number_helpers import _coerce_float
from auth_decorators import require_permission

from pricing.karat_service import convert_from_main_karat, convert_to_main_karat, get_main_karat
from accounting.voucher_engine import _update_account_balances_from_journal_lines
from accounting.safe_boxes import _rebuild_safe_box_transactions_for_journal_entry
from accounting.balances import _recalculate_account_balances_for_accounts
from routes import (
    get_current_gold_price,
)

journals_bp = Blueprint('journals', __name__)

def _parse_journal_entries_query_datetime(value, *, end_of_day=False):
    if not value:
        return None

    try:
        normalized = str(value).strip().replace('Z', '+00:00')
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone().replace(tzinfo=None)
        if end_of_day and parsed.hour == 0 and parsed.minute == 0 and parsed.second == 0 and parsed.microsecond == 0:
            parsed = parsed + timedelta(days=1) - timedelta(microseconds=1)
        return parsed
    except Exception:
        return None

def _journal_entry_line_to_dict(line):
    try:
        account_name = line.account.name if line.account else f'حساب محذوف (ID: {line.account_id})'
    except Exception:
        account_name = f'حساب (ID: {getattr(line, "account_id", "?")})'
    return {
        'id': line.id,
        'account_id': line.account_id,
        'account_name': account_name,
        'cash_debit': float(getattr(line, 'cash_debit', None) or 0.0),
        'cash_credit': float(getattr(line, 'cash_credit', None) or 0.0),
        'debit_18k': float(getattr(line, 'debit_18k', None) or 0.0),
        'credit_18k': float(getattr(line, 'credit_18k', None) or 0.0),
        'debit_21k': float(getattr(line, 'debit_21k', None) or 0.0),
        'credit_21k': float(getattr(line, 'credit_21k', None) or 0.0),
        'debit_22k': float(getattr(line, 'debit_22k', None) or 0.0),
        'credit_22k': float(getattr(line, 'credit_22k', None) or 0.0),
        'debit_24k': float(getattr(line, 'debit_24k', None) or 0.0),
        'credit_24k': float(getattr(line, 'credit_24k', None) or 0.0),
    }

def _journal_entry_totals(lines):
    cash_debit = 0.0
    cash_credit = 0.0
    gold_debit_main = 0.0
    gold_credit_main = 0.0

    for line in lines:
        cash_debit += float(line.get('cash_debit') or 0.0)
        cash_credit += float(line.get('cash_credit') or 0.0)

        gold_debit_main += convert_to_main_karat(float(line.get('debit_18k') or 0.0), 18)
        gold_debit_main += convert_to_main_karat(float(line.get('debit_21k') or 0.0), 21)
        gold_debit_main += convert_to_main_karat(float(line.get('debit_22k') or 0.0), 22)
        gold_debit_main += convert_to_main_karat(float(line.get('debit_24k') or 0.0), 24)

        gold_credit_main += convert_to_main_karat(float(line.get('credit_18k') or 0.0), 18)
        gold_credit_main += convert_to_main_karat(float(line.get('credit_21k') or 0.0), 21)
        gold_credit_main += convert_to_main_karat(float(line.get('credit_22k') or 0.0), 22)
        gold_credit_main += convert_to_main_karat(float(line.get('credit_24k') or 0.0), 24)

    return {
        'cash_debit': round(cash_debit, 2),
        'cash_credit': round(cash_credit, 2),
        'cash_total': round(max(cash_debit, cash_credit), 2),
        'gold_debit_main_karat': round(gold_debit_main, 6),
        'gold_credit_main_karat': round(gold_credit_main, 6),
        'gold_total_main_karat': round(max(gold_debit_main, gold_credit_main), 6),
    }

def _serialize_journal_entry_list_item(entry):
    try:
        lines = [
            _journal_entry_line_to_dict(line)
            for line in entry.lines
            if not getattr(line, 'is_deleted', False)
        ]
    except Exception:
        lines = []
    totals = _journal_entry_totals(lines)
    account_names = []
    seen_names = set()
    for line in lines:
        account_name = (line.get('account_name') or '').strip()
        if not account_name or account_name in seen_names:
            continue
        seen_names.add(account_name)
        account_names.append(account_name)

    creator_name = (getattr(entry, 'created_by', None) or getattr(entry, 'posted_by', None) or '').strip()
    reference_display = ' - '.join(
        part for part in [
            (getattr(entry, 'reference_type', None) or '').strip(),
            (getattr(entry, 'reference_number', None) or '').strip(),
        ]
        if part
    )

    return {
        'id': entry.id,
        'entry_number': entry.entry_number,
        'date': entry.date.isoformat() if entry.date else None,
        'created_at': entry.created_at.isoformat() if getattr(entry, 'created_at', None) else None,
        'description': entry.description,
        'entry_type': getattr(entry, 'entry_type', None) or 'عادي',
        'status': 'posted' if bool(getattr(entry, 'is_posted', False)) else 'unposted',
        'is_draft': bool(getattr(entry, 'is_draft', False)) and not bool(getattr(entry, 'is_posted', False)),
        'is_posted': bool(getattr(entry, 'is_posted', False)),
        'posted_at': entry.posted_at.isoformat() if getattr(entry, 'posted_at', None) else None,
        'posted_by': getattr(entry, 'posted_by', None),
        'created_by': getattr(entry, 'created_by', None),
        'creator_name': creator_name or None,
        'reference_type': getattr(entry, 'reference_type', None),
        'reference_id': getattr(entry, 'reference_id', None),
        'reference_number': getattr(entry, 'reference_number', None),
        'reference_display': reference_display or None,
        'line_count': len(lines),
        'accounts_count': len(account_names),
        'accounts_preview': account_names[:3],
        'lines': lines,
        **totals,
    }

@journals_bp.route('/journal_entries', methods=['GET'])
@require_permission('journal.view')
def get_journal_entries():
    page = request.args.get('page', 1, type=int) or 1
    per_page = request.args.get('per_page', 20, type=int) or 20
    per_page = max(1, min(per_page, 100))

    search = (request.args.get('search') or '').strip()
    search_type = (request.args.get('search_type') or 'all').strip().lower()
    status = (request.args.get('status') or 'all').strip().lower()
    entry_type = (request.args.get('entry_type') or 'all').strip()
    creator = (request.args.get('creator') or '').strip()
    sort_by = (request.args.get('sort_by') or 'date').strip().lower()
    sort_order = (request.args.get('sort_order') or 'desc').strip().lower()
    account_id = request.args.get('account_id', type=int)
    min_cash = _coerce_float(request.args.get('min_cash'), None)
    max_cash = _coerce_float(request.args.get('max_cash'), None)
    date_from = _parse_journal_entries_query_datetime(request.args.get('date_from'))
    date_to = _parse_journal_entries_query_datetime(request.args.get('date_to'), end_of_day=True)
    response_format = (request.args.get('format') or '').strip().lower()
    paginate_response = response_format != 'list' and (request.args.get('paginate') or 'true').strip().lower() not in ('0', 'false', 'no')

    query = (
        JournalEntry.query
        .options(joinedload(JournalEntry.lines).joinedload(JournalEntryLine.account))
        .filter(JournalEntry.is_deleted == False)
    )

    if status == 'posted':
        query = query.filter(JournalEntry.is_posted == True)
    elif status == 'unposted':
        query = query.filter(JournalEntry.is_posted == False)

    if entry_type and entry_type != 'all':
        query = query.filter(JournalEntry.entry_type == entry_type)

    if account_id:
        query = query.filter(
            JournalEntry.lines.any(
                and_(
                    JournalEntryLine.account_id == account_id,
                    JournalEntryLine.is_deleted == False,
                )
            )
        )

    if date_from is not None:
        query = query.filter(JournalEntry.date >= date_from)
    if date_to is not None:
        query = query.filter(JournalEntry.date <= date_to)

    if search:
        id_query = search.replace('#', '').strip()
        base_search_filters = [
            JournalEntry.entry_number.ilike(f'%{search}%'),
            JournalEntry.description.ilike(f'%{search}%'),
            JournalEntry.reference_number.ilike(f'%{search}%'),
            JournalEntry.reference_type.ilike(f'%{search}%'),
            JournalEntry.entry_type.ilike(f'%{search}%'),
            JournalEntry.created_by.ilike(f'%{search}%'),
            JournalEntry.posted_by.ilike(f'%{search}%'),
        ]

        if id_query.isdigit():
            base_search_filters.append(cast(JournalEntry.id, String) == id_query)

        if search_type == 'id' and id_query.isdigit():
            query = query.filter(cast(JournalEntry.id, String) == id_query)
        elif search_type == 'number':
            query = query.filter(JournalEntry.entry_number.ilike(f'%{search}%'))
        elif search_type == 'description':
            query = query.filter(JournalEntry.description.ilike(f'%{search}%'))
        elif search_type == 'reference':
            query = query.filter(
                or_(
                    JournalEntry.reference_number.ilike(f'%{search}%'),
                    JournalEntry.reference_type.ilike(f'%{search}%'),
                )
            )
        elif search_type == 'creator':
            query = query.filter(
                or_(
                    JournalEntry.created_by.ilike(f'%{search}%'),
                    JournalEntry.posted_by.ilike(f'%{search}%'),
                )
            )
        elif search_type != 'amount' and search_type != 'gold':
            query = query.filter(or_(*base_search_filters))

    entries = query.order_by(
        JournalEntry.date.desc(),
        JournalEntry.id.desc(),
    )

    # Determine if we need Python-side post-filtering (prevents SQL pagination).
    needs_python_filter = bool(creator) or (search and search_type in ('amount', 'gold')) or min_cash is not None or max_cash is not None

    if needs_python_filter or not paginate_response:
        all_entries = entries.all()
    else:
        # Fast path: SQL pagination — only fetch summary counts + current page.
        base_q = entries.order_by(None)  # strip ORDER BY for count queries
        total_count = base_q.with_entities(func.count(JournalEntry.id)).scalar() or 0
        posted_count = base_q.filter(JournalEntry.is_posted == True).with_entities(func.count(JournalEntry.id)).scalar() or 0

        total_pages_sql = max(1, (total_count + per_page - 1) // per_page) if total_count else 1
        current_page_sql = min(max(page, 1), total_pages_sql)
        page_entries = entries.offset((current_page_sql - 1) * per_page).limit(per_page).all()

        try:
            serialized_page = [_serialize_journal_entry_list_item(e) for e in page_entries]
        except Exception as _ser_exc:
            import traceback as _tb
            _tb.print_exc()
            return jsonify({'error': 'serialization_failed', 'message': str(_ser_exc)}), 500

        page_cash = round(sum(float(e.get('cash_total') or 0.0) for e in serialized_page), 2)
        page_gold = round(sum(float(e.get('gold_total_main_karat') or 0.0) for e in serialized_page), 6)

        available_creators_q = (
            JournalEntry.query
            .filter(JournalEntry.is_deleted == False)
            .with_entities(JournalEntry.created_by)
            .distinct()
            .all()
        )
        available_types_q = (
            JournalEntry.query
            .filter(JournalEntry.is_deleted == False)
            .with_entities(JournalEntry.entry_type)
            .distinct()
            .all()
        )

        return jsonify({
            'journal_entries': serialized_page,
            'total': total_count,
            'pages': total_pages_sql,
            'current_page': current_page_sql,
            'per_page': per_page,
            'current_summary': {
                'total_entries': total_count,
                'posted_count': posted_count,
                'unposted_count': total_count - posted_count,
                'total_cash': page_cash,
                'total_gold_main_karat': page_gold,
            },
            'available_creators': [{'name': (r[0] or '').strip()} for r in available_creators_q if (r[0] or '').strip()],
            'available_entry_types': [{'name': (r[0] or '').strip()} for r in available_types_q if (r[0] or '').strip()],
        })

    try:
        serialized_entries = [_serialize_journal_entry_list_item(entry) for entry in all_entries]
    except Exception as _ser_exc:
        import traceback as _tb
        _tb.print_exc()
        return jsonify({'error': 'serialization_failed', 'message': str(_ser_exc)}), 500

    if creator:
        serialized_entries = [
            entry for entry in serialized_entries
            if (entry.get('creator_name') or '').strip() == creator
        ]

    if search:
        normalized_search = search.strip().lower()
        numeric_search = _coerce_float(normalized_search, None)

        if search_type == 'amount':
            serialized_entries = [
                entry for entry in serialized_entries
                if (
                    numeric_search is not None and abs(float(entry.get('cash_total') or 0.0) - numeric_search) < 0.0001
                ) or normalized_search in f"{float(entry.get('cash_total') or 0.0):.2f}".lower()
            ]
        elif search_type == 'gold':
            serialized_entries = [
                entry for entry in serialized_entries
                if (
                    numeric_search is not None and abs(float(entry.get('gold_total_main_karat') or 0.0) - numeric_search) < 0.0001
                ) or normalized_search in f"{float(entry.get('gold_total_main_karat') or 0.0):.6f}".lower()
            ]

    if min_cash is not None:
        serialized_entries = [
            entry for entry in serialized_entries
            if float(entry.get('cash_total') or 0.0) >= min_cash
        ]
    if max_cash is not None:
        serialized_entries = [
            entry for entry in serialized_entries
            if float(entry.get('cash_total') or 0.0) <= max_cash
        ]

    reverse = sort_order != 'asc'

    def _sort_key(entry):
        if sort_by == 'id':
            return int(entry.get('id') or 0)
        if sort_by == 'number':
            return (entry.get('entry_number') or '').strip().lower()
        if sort_by == 'description':
            return (entry.get('description') or '').strip().lower()
        if sort_by == 'status':
            return (entry.get('status') or '').strip().lower()
        if sort_by == 'type':
            return (entry.get('entry_type') or '').strip().lower()
        if sort_by == 'cash':
            return float(entry.get('cash_total') or 0.0)
        if sort_by == 'gold':
            return float(entry.get('gold_total_main_karat') or 0.0)
        if sort_by == 'reference':
            return (entry.get('reference_display') or '').strip().lower()
        if sort_by == 'creator':
            return (entry.get('creator_name') or '').strip().lower()
        return (
            entry.get('created_at') or entry.get('date') or '',
            entry.get('date') or '',
            int(entry.get('id') or 0),
        )

    serialized_entries.sort(key=_sort_key, reverse=reverse)

    current_summary = {
        'total_entries': len(serialized_entries),
        'posted_count': sum(1 for entry in serialized_entries if entry.get('is_posted') == True),
        'unposted_count': sum(1 for entry in serialized_entries if entry.get('is_posted') != True),
        'total_cash': round(sum(float(entry.get('cash_total') or 0.0) for entry in serialized_entries), 2),
        'total_gold_main_karat': round(sum(float(entry.get('gold_total_main_karat') or 0.0) for entry in serialized_entries), 6),
    }

    available_creators = sorted({
        (entry.get('creator_name') or '').strip()
        for entry in serialized_entries
        if (entry.get('creator_name') or '').strip()
    })
    available_entry_types = sorted({
        (entry.get('entry_type') or '').strip()
        for entry in serialized_entries
        if (entry.get('entry_type') or '').strip()
    })

    if not paginate_response:
        return jsonify(serialized_entries)

    total_entries = len(serialized_entries)
    total_pages = max(1, (total_entries + per_page - 1) // per_page) if total_entries else 1
    current_page = min(max(page, 1), total_pages)
    start = (current_page - 1) * per_page
    end = start + per_page
    page_items = serialized_entries[start:end]

    return jsonify({
        'journal_entries': page_items,
        'total': total_entries,
        'pages': total_pages,
        'current_page': current_page,
        'per_page': per_page,
        'current_summary': current_summary,
        'available_creators': [{'name': name} for name in available_creators],
        'available_entry_types': [{'name': name} for name in available_entry_types],
    })

from dual_distribution_service import distribute_lines as _distribute_lines


@journals_bp.route('/journal_entries', methods=['POST'])
@require_permission('journal.create')
def add_journal_entry():
    """
    إضافة قيد يومية يدوي
    
    🆕 دعم القاعدة الذهبية:
    - إذا كان apply_golden_rule=true في الطلب، يتم تطبيق القاعدة تلقائياً
    - القاعدة: الوزن = المبلغ النقدي ÷ سعر الذهب المباشر
    - يمكن تعطيل القاعدة بإرسال apply_golden_rule=false
    """
    data = request.get_json() or {}
    lines_data = data.get('lines', []) or []
    requested_is_draft = bool(data.get('is_draft', False))
    
    # 🆕 التحقق من طلب تطبيق القاعدة الذهبية
    apply_golden_rule = data.get('apply_golden_rule', False)
    
    if apply_golden_rule:
        # الحصول على سعر الذهب الحالي
        try:
            from dual_system_helpers import apply_golden_rule_to_line
            gold_price_data = get_current_gold_price()
            gold_price_main_karat = gold_price_data['price_per_gram_main_karat']  # 🔥 سعر العيار الرئيسي
            main_karat = gold_price_data['main_karat']  # 🔥 العيار الرئيسي
            
            # تطبيق القاعدة على كل سطر
            lines_data = [
                apply_golden_rule_to_line(line, gold_price_main_karat, main_karat, apply_rule=True)
                for line in lines_data
            ]
            
            print(f"✅ تم تطبيق القاعدة الذهبية (سعر عيار {main_karat}: {gold_price_main_karat} ريال/جرام)")
        except Exception as e:
            print(f"⚠️  تعذر تطبيق القاعدة الذهبية: {e}")
            # نكمل بدون تطبيق القاعدة

    # --- Pre-validation ---
    # Filter out completely empty lines first
    lines_data = [
        line for line in lines_data if any([
            line.get('cash_debit', 0), line.get('cash_credit', 0),
            line.get('debit_18k', 0), line.get('credit_18k', 0),
            line.get('debit_21k', 0), line.get('credit_21k', 0),
            line.get('debit_22k', 0), line.get('credit_22k', 0),
            line.get('debit_24k', 0), line.get('credit_24k', 0)
        ]) or line.get('account_id')
    ]

    # Check if any line with data is missing an account
    for line in lines_data:
        has_values = any([
            line.get('cash_debit', 0), line.get('cash_credit', 0),
            line.get('debit_18k', 0), line.get('credit_18k', 0),
            line.get('debit_21k', 0), line.get('credit_21k', 0),
            line.get('debit_22k', 0), line.get('credit_22k', 0),
            line.get('debit_24k', 0), line.get('credit_24k', 0)
        ])
        if has_values and not line.get('account_id'):
            return jsonify({'error': 'Each line must have an associated account.'}), 400

    # Auto-route: split mixed-value lines for dual-account pairs (cash↔gold).
    lines_data = _distribute_lines(lines_data)

    if not requested_is_draft:
        if not lines_data or len(lines_data) < 2:
            return jsonify({'error': 'يجب أن يحتوي قيد اليومية على سطرين على الأقل.'}), 400

    if not requested_is_draft:
        # --- Balance Validation ---
        total_cash_debit = sum(line.get('cash_debit', 0) for line in lines_data)
        total_cash_credit = sum(line.get('cash_credit', 0) for line in lines_data)

        if round(total_cash_debit, 3) != round(total_cash_credit, 3):
            return jsonify({'error': 'Cash debits and credits must be balanced.'}), 400

        # --- Gold Balance Calculation and Auto-Balancing ---
        total_gold_debit_normalized = sum(
            convert_to_main_karat(line.get('debit_18k', 0), 18) +
            convert_to_main_karat(line.get('debit_21k', 0), 21) +
            convert_to_main_karat(line.get('debit_22k', 0), 22) +
            convert_to_main_karat(line.get('debit_24k', 0), 24)
            for line in lines_data
        )
        total_gold_credit_normalized = sum(
            convert_to_main_karat(line.get('credit_18k', 0), 18) +
            convert_to_main_karat(line.get('credit_21k', 0), 21) +
            convert_to_main_karat(line.get('credit_22k', 0), 22) +
            convert_to_main_karat(line.get('credit_24k', 0), 24)
            for line in lines_data
        )

        gold_difference = total_gold_debit_normalized - total_gold_credit_normalized

        # Auto-balance if the difference is negligible (less than 0.01)
        if 0 < abs(gold_difference) < 0.01:
            adjustment_applied = False
            # If debit is greater, increase a credit line
            if gold_difference > 0:
                for line in lines_data:
                    # Find a line with any credit amount to adjust
                    if any(line.get(f'credit_{k}k', 0) > 0 for k in [18, 21, 22, 24]):
                        # Adjust the first available credit karat (prefer 21k)
                        if line.get('credit_21k', 0) > 0:
                            line['credit_21k'] += convert_from_main_karat(gold_difference, 21)
                        elif line.get('credit_18k', 0) > 0:
                            line['credit_18k'] += convert_from_main_karat(gold_difference, 18)
                        elif line.get('credit_22k', 0) > 0:
                            line['credit_22k'] += convert_from_main_karat(gold_difference, 22)
                        elif line.get('credit_24k', 0) > 0:
                            line['credit_24k'] += convert_from_main_karat(gold_difference, 24)
                        adjustment_applied = True
                        break
            # If credit is greater, increase a debit line
            else:  # gold_difference < 0
                for line in lines_data:
                    # Find a line with any debit amount to adjust
                    if any(line.get(f'debit_{k}k', 0) > 0 for k in [18, 21, 22, 24]):
                        # Adjust the first available debit karat (prefer 21k)
                        if line.get('debit_21k', 0) > 0:
                            line['debit_21k'] -= convert_from_main_karat(gold_difference, 21)  # subtract negative diff
                        elif line.get('debit_18k', 0) > 0:
                            line['debit_18k'] -= convert_from_main_karat(gold_difference, 18)
                        elif line.get('debit_22k', 0) > 0:
                            line['debit_22k'] -= convert_from_main_karat(gold_difference, 22)
                        elif line.get('debit_24k', 0) > 0:
                            line['debit_24k'] -= convert_from_main_karat(gold_difference, 24)
                        adjustment_applied = True
                        break

            # Recalculate totals if an adjustment was made
            if adjustment_applied:
                total_gold_debit_normalized = sum(
                    convert_to_main_karat(line.get('debit_18k', 0), 18) +
                    convert_to_main_karat(line.get('debit_21k', 0), 21) +
                    convert_to_main_karat(line.get('debit_22k', 0), 22) +
                    convert_to_main_karat(line.get('debit_24k', 0), 24)
                    for line in lines_data
                )
                total_gold_credit_normalized = sum(
                    convert_to_main_karat(line.get('credit_18k', 0), 18) +
                    convert_to_main_karat(line.get('credit_21k', 0), 21) +
                    convert_to_main_karat(line.get('credit_22k', 0), 22) +
                    convert_to_main_karat(line.get('credit_24k', 0), 24)
                    for line in lines_data
                )

        # Final check for gold balance after potential auto-balancing
        if round(total_gold_debit_normalized, 3) != round(total_gold_credit_normalized, 3):
            return jsonify({'error': f'Gold debits and credits must be balanced when normalized to main karat. Debit: {total_gold_debit_normalized}, Credit: {total_gold_credit_normalized}'}), 400
        # --- End Balance Validation ---

    try:
        new_entry = JournalEntry(
            date=datetime.fromisoformat(data['date']),
            description=data['description'],
            is_draft=requested_is_draft,
            entry_type=data.get('entry_type', 'عادي'),  # 🆕 نوع القيد
            reference_type=data.get('reference_type'),
            reference_number=data.get('reference_number'),
            created_by=actor(),   # the session's user (ADR-036 R4); a manual entry recorded none
        )
        db.session.add(new_entry)
        db.session.flush() # Get the ID for the lines

        created_lines = []
        for line_data in lines_data:
            new_line = JournalEntryLine(
                journal_entry_id=new_entry.id,
                account_id=line_data['account_id'],
                cash_debit=line_data.get('cash_debit', 0),
                cash_credit=line_data.get('cash_credit', 0),
                debit_18k=line_data.get('debit_18k', 0),
                credit_18k=line_data.get('credit_18k', 0),
                debit_21k=line_data.get('debit_21k', 0),
                credit_21k=line_data.get('credit_21k', 0),
                debit_22k=line_data.get('debit_22k', 0),
                credit_22k=line_data.get('credit_22k', 0),
                debit_24k=line_data.get('debit_24k', 0),
                credit_24k=line_data.get('credit_24k', 0)
            )
            db.session.add(new_line)
            created_lines.append(new_line)

        db.session.flush()
        
        # Update balances only for non-draft entries.
        if not requested_is_draft:
            _update_account_balances_from_journal_lines(created_lines)

        # 🆕 Check auto_post_entries setting
        if not requested_is_draft:
            _auto_post_je = False
            try:
                _je_posting_settings = Settings.query.first()
                if _je_posting_settings:
                    _auto_post_je = bool(getattr(_je_posting_settings, 'auto_post_entries', False))
            except Exception:
                _auto_post_je = False

            # Who creates does not post (ADR-036 R4): auto-posting at creation is the
            # owner's alone; anyone else's entry waits for another to post it.
            if _auto_post_je and may_approve_own():
                new_entry.is_posted = True
                new_entry.posted_at = datetime.now()
                new_entry.posted_by = getattr(g, 'current_user', None) and getattr(g.current_user, 'username', 'system') or 'system'

        # Keep SafeBoxTransaction ledger in sync for manual-like posted journal entries.
        try:
            posted_by = getattr(g, 'current_user', None) and getattr(g.current_user, 'username', None)
        except Exception:
            posted_by = None
        posted_by = posted_by or 'system'
        try:
            _rebuild_safe_box_transactions_for_journal_entry(new_entry, created_lines, created_by=posted_by)
        except Exception:
            # best-effort: never block journal creation
            pass

        db.session.commit()
        return jsonify(new_entry.to_dict()), 201
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'Failed to save journal entry', 'details': str(e)}), 500

@journals_bp.route('/journal_entries/<int:id>', methods=['GET'])
@require_permission('journal.view')
def get_journal_entry(id):
    entry = JournalEntry.query.get_or_404(id)
    lines = []
    for line in entry.lines:
        if line.is_deleted:
            continue
        lines.append({
            'id': line.id,
            'account_id': line.account_id,
            'account_name': line.account.name if line.account else 'Unknown Account',
            'cash_debit': line.cash_debit,
            'cash_credit': line.cash_credit,
            'debit_18k': line.debit_18k,
            'credit_18k': line.credit_18k,
            'debit_21k': line.debit_21k,
            'credit_21k': line.credit_21k,
            'debit_22k': line.debit_22k,
            'credit_22k': line.credit_22k,
            'debit_24k': line.debit_24k,
            'credit_24k': line.credit_24k,
        })
    return jsonify({
        'id': entry.id,
        'date': entry.date.isoformat(),
        'description': entry.description,
        'entry_number': entry.entry_number,
        'entry_type': getattr(entry, 'entry_type', None),
        'is_draft': bool(getattr(entry, 'is_draft', False)),
        'reference_type': getattr(entry, 'reference_type', None),
        'reference_id': getattr(entry, 'reference_id', None),
        'reference_number': getattr(entry, 'reference_number', None),
        'lines': lines
    })

@journals_bp.route('/journal_entries/<int:id>', methods=['PUT'])
@require_permission('journal.edit')
def update_journal_entry(id):
    entry = JournalEntry.query.get_or_404(id)
    data = request.get_json() or {}
    target_is_draft = bool(data.get('is_draft', getattr(entry, 'is_draft', False)))

    incoming_lines = data.get('lines', []) or []

    # Filter out completely empty lines
    incoming_lines = [
        line for line in incoming_lines if any([
            line.get('cash_debit', 0), line.get('cash_credit', 0),
            line.get('debit_18k', 0), line.get('credit_18k', 0),
            line.get('debit_21k', 0), line.get('credit_21k', 0),
            line.get('debit_22k', 0), line.get('credit_22k', 0),
            line.get('debit_24k', 0), line.get('credit_24k', 0)
        ]) or line.get('account_id')
    ]

    # Lines with values must have an account
    for line in incoming_lines:
        has_values = any([
            line.get('cash_debit', 0), line.get('cash_credit', 0),
            line.get('debit_18k', 0), line.get('credit_18k', 0),
            line.get('debit_21k', 0), line.get('credit_21k', 0),
            line.get('debit_22k', 0), line.get('credit_22k', 0),
            line.get('debit_24k', 0), line.get('credit_24k', 0)
        ])
        if has_values and not line.get('account_id'):
            return jsonify({'error': 'Each line must have an associated account.'}), 400

    # Auto-route: split mixed-value lines for dual-account pairs (cash↔gold).
    incoming_lines = _distribute_lines(incoming_lines)

    if not target_is_draft:
        if not incoming_lines or len(incoming_lines) < 2:
            return jsonify({'error': 'A journal entry must have at least two lines.'}), 400

        # --- Balance Validation ---
        total_cash_debit = sum(line.get('cash_debit', 0) for line in incoming_lines)
        total_cash_credit = sum(line.get('cash_credit', 0) for line in incoming_lines)

        if round(total_cash_debit, 3) != round(total_cash_credit, 3):
            return jsonify({'error': 'Cash debits and credits must be balanced.'}), 400

        total_gold_debit_normalized = sum(
            convert_to_main_karat(line.get('debit_18k', 0), 18) +
            convert_to_main_karat(line.get('debit_21k', 0), 21) +
            convert_to_main_karat(line.get('debit_22k', 0), 22) +
            convert_to_main_karat(line.get('debit_24k', 0), 24)
            for line in incoming_lines
        )
        total_gold_credit_normalized = sum(
            convert_to_main_karat(line.get('credit_18k', 0), 18) +
            convert_to_main_karat(line.get('credit_21k', 0), 21) +
            convert_to_main_karat(line.get('credit_22k', 0), 22) +
            convert_to_main_karat(line.get('credit_24k', 0), 24)
            for line in incoming_lines
        )

        if round(total_gold_debit_normalized, 3) != round(total_gold_credit_normalized, 3):
            return jsonify({'error': f'Gold debits and credits must be balanced when normalized to main karat. Debit: {total_gold_debit_normalized}, Credit: {total_gold_credit_normalized}'}), 400
        # --- End Balance Validation ---

    try:
        entry.date = datetime.fromisoformat(data['date'])
        entry.description = data['description']
        # 🆕 تحديث حالة المسودة إذا تم إرسالها
        if 'is_draft' in data:
            entry.is_draft = bool(data['is_draft'])

        # حفظ معرفات الحسابات المتأثرة من الأسطر القديمة
        old_account_ids = {line.account_id for line in entry.lines if line.account_id}

        # Remove old lines
        for line in entry.lines:
            db.session.delete(line)

        db.session.flush()

        # Add new lines
        new_lines = []
        for line_data in incoming_lines:
            new_line = JournalEntryLine(
                journal_entry_id=entry.id,
                account_id=line_data['account_id'],
                cash_debit=line_data.get('cash_debit', 0),
                cash_credit=line_data.get('cash_credit', 0),
                debit_18k=line_data.get('debit_18k', 0),
                credit_18k=line_data.get('credit_18k', 0),
                debit_21k=line_data.get('debit_21k', 0),
                credit_21k=line_data.get('credit_21k', 0),
                debit_22k=line_data.get('debit_22k', 0),
                credit_22k=line_data.get('credit_22k', 0),
                debit_24k=line_data.get('debit_24k', 0),
                credit_24k=line_data.get('credit_24k', 0),
            )
            db.session.add(new_line)
            new_lines.append(new_line)

        db.session.flush()
        
        # 🆕 تحديث أرصدة جميع الحسابات المتأثرة (القديمة والجديدة)
        affected_accounts = old_account_ids | {line.account_id for line in new_lines if line.account_id}
        _recalculate_account_balances_for_accounts(affected_accounts)

        # Rebuild SafeBoxTransaction ledger rows for manual-like journal entries.
        try:
            posted_by = getattr(g, 'current_user', None) and getattr(g.current_user, 'username', None)
        except Exception:
            posted_by = None
        posted_by = posted_by or 'system'
        try:
            _rebuild_safe_box_transactions_for_journal_entry(entry, new_lines, created_by=posted_by)
        except Exception:
            pass

        db.session.commit()
        return jsonify({'result': 'success'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'Failed to update journal entry', 'detail': str(e)}), 500

# ===== نظام الحذف الآمن (Soft Delete) =====

@journals_bp.route('/journal_entries/<int:id>/soft_delete', methods=['POST'])
@require_permission('journal.delete')
def soft_delete_journal_entry(id):
    """حذف ناعم للقيد مع تسجيل المعلومات"""
    entry = JournalEntry.query.get_or_404(id)
    from journal_entry_guard import refusal_for
    _refused = refusal_for(entry, 'delete')
    if _refused:
        return jsonify({'error': _refused[0], 'message': _refused[1]}), 409
    
    # التحقق من أن القيد غير محذوف مسبقاً
    if entry.is_deleted:
        return jsonify({'error': 'القيد محذوف مسبقاً'}), 400
    
    data = request.get_json() or {}
    deleted_by = data.get('deleted_by', 'غير محدد')
    reason = data.get('reason', '')
    
    try:
        affected_account_ids = {line.account_id for line in entry.lines if line.account_id}

        # تطبيق الحذف الناعم
        entry.soft_delete(deleted_by, reason)
        
        # حذف ناعم للأسطر المرتبطة
        from datetime import datetime
        for line in entry.lines:
            line.is_deleted = True
            line.deleted_at = datetime.now()

        # إعادة حساب أرصدة الحسابات المتأثرة
        _recalculate_account_balances_for_accounts(affected_account_ids)

        # Remove derived safebox ledger rows for this journal entry.
        try:
            # 1. SBTs created directly from this JE (ref_type='journal_entry')
            SafeBoxTransaction.query.filter_by(ref_type='journal_entry', ref_id=int(entry.id)).delete(synchronize_session=False)
        except Exception:
            pass
        try:
            # 2. If this JE is a voucher reversal, remove the voucher_reversal SBTs
            #    (ref_type='voucher_reversal', ref_id = the original voucher id).
            #    These become orphans the moment the reversal JE is deleted.
            if entry.reference_type == 'voucher_reversal' and entry.reference_id:
                SafeBoxTransaction.query.filter_by(
                    ref_type='voucher_reversal', ref_id=int(entry.reference_id)
                ).delete(synchronize_session=False)
        except Exception:
            pass
        try:
            # 3. If this JE is for a voucher being un-approved/deleted, also remove
            #    the voucher SBTs so the sub-ledger stays consistent.
            if entry.reference_type == 'voucher' and entry.reference_id:
                SafeBoxTransaction.query.filter_by(
                    ref_type='voucher', ref_id=int(entry.reference_id)
                ).delete(synchronize_session=False)
        except Exception:
            pass

        # Cascade: if this JE belongs to an invoice, mark the invoice as unposted.
        # The JE no longer counts in GL so the invoice should reflect that.
        if entry.reference_type == 'invoice' and entry.reference_id:
            try:
                linked_inv = Invoice.query.get(entry.reference_id)
                if linked_inv and linked_inv.is_posted:
                    linked_inv.is_posted = False
                    linked_inv.posted_at = None
                    # Remove category-weight movements; only valid for posted invoices.
                    try:
                        from models import CategoryWeightMovement
                        CategoryWeightMovement.query.filter_by(invoice_id=linked_inv.id).delete()
                    except Exception:
                        pass
            except Exception:
                pass

        # Cascade: if this JE belongs to a voucher (directly), reset voucher to pending.
        if entry.reference_type == 'voucher' and entry.reference_id:
            try:
                linked_v = Voucher.query.get(entry.reference_id)
                if linked_v and linked_v.status == 'approved':
                    linked_v.status = 'pending'
                    linked_v.journal_entry_id = None
            except Exception:
                pass

        db.session.commit()
        
        return jsonify({
            'result': 'success',
            'message': 'تم حذف القيد بنجاح (يمكن الاسترجاع)',
            'can_restore': True,
            'deleted_at': entry.deleted_at.isoformat(),
            'deleted_by': entry.deleted_by
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'فشل حذف القيد', 'detail': str(e)}), 500

@journals_bp.route('/journal_entries/<int:id>/restore', methods=['POST'])
@require_permission('journal.delete')
def restore_journal_entry(id):
    """استرجاع قيد محذوف"""
    entry = JournalEntry.query.filter_by(id=id, is_deleted=True).first_or_404()
    from journal_entry_guard import refusal_for
    _refused = refusal_for(entry, 'restore')
    if _refused:
        return jsonify({'error': _refused[0], 'message': _refused[1]}), 409
    
    data = request.get_json() or {}
    restored_by = data.get('restored_by', 'غير محدد')
    
    try:
        affected_account_ids = {line.account_id for line in entry.lines if line.account_id}

        # استرجاع القيد
        entry.restore(restored_by)
        
        # استرجاع الأسطر
        for line in entry.lines:
            line.is_deleted = False
            line.deleted_at = None

        # إعادة حساب أرصدة الحسابات المتأثرة
        _recalculate_account_balances_for_accounts(affected_account_ids)

        # Rebuild derived safebox ledger rows for manual journal entries.
        try:
            posted_by = restored_by or 'system'
        except Exception:
            posted_by = 'system'
        try:
            _rebuild_safe_box_transactions_for_journal_entry(entry, [l for l in entry.lines if not getattr(l, 'is_deleted', False)], created_by=posted_by)
        except Exception:
            pass
        
        db.session.commit()
        
        return jsonify({
            'result': 'success',
            'message': 'تم استرجاع القيد بنجاح',
            'restored_at': entry.restored_at.isoformat(),
            'restored_by': entry.restored_by
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'فشل استرجاع القيد', 'detail': str(e)}), 500

@journals_bp.route('/journal_entries/deleted', methods=['GET'])
@require_permission('journal.view')
def get_deleted_journal_entries():
    """عرض القيود المحذوفة"""
    entries = JournalEntry.query.filter_by(is_deleted=True).order_by(JournalEntry.deleted_at.desc()).all()
    return jsonify([entry.to_dict(include_deleted_info=True) for entry in entries])

@journals_bp.route('/journal_entries/<int:id>', methods=['DELETE'])
@require_permission('journal.delete')   # none until UNPOST-001 U3: any signed-in user could
def delete_journal_entry(id):
    """حذف نهائي للقيد (Hard Delete) - للاستخدام الإداري فقط"""
    entry = JournalEntry.query.get_or_404(id)
    from journal_entry_guard import refusal_for
    _refused = refusal_for(entry, 'delete')
    if _refused:
        return jsonify({'error': _refused[0], 'message': _refused[1]}), 409
    try:
        from models import (
            WeightClosingOrder, WeightClosingExecution, 
            SupplierGoldTransaction, InvoicePayment
        )
        
        # حذف الأسطر أولاً (cascade)
        for line in entry.lines[:]:
            db.session.delete(line)
        
        # إزالة المراجع من الجداول الأخرى
        # 1. الفواتير — unpost when their JE is hard-deleted
        # Invoice model does not have journal_entry_id column; link is via JournalEntry.reference_id
        invoices = []
        # Also cascade via reference_type link (invoice JEs use reference_type, not invoice.journal_entry_id)
        ref_invoices = Invoice.query.join(
            JournalEntry,
            (JournalEntry.reference_type == 'invoice') & (JournalEntry.reference_id == Invoice.id) & (JournalEntry.id == entry.id)
        ).all()
        for inv in ref_invoices:
            if inv not in invoices and inv.is_posted:
                inv.is_posted = False
                inv.posted_at = None
                try:
                    from models import CategoryWeightMovement
                    CategoryWeightMovement.query.filter_by(invoice_id=inv.id).delete()
                except Exception:
                    pass
        
        # 2. السندات — reset to pending when their JE is hard-deleted
        vouchers = Voucher.query.filter_by(journal_entry_id=entry.id).all()
        for v in vouchers:
            v.journal_entry_id = None
            if v.status == 'approved':
                v.status = 'pending'
        
        # 3. أوامر إقفال الأوزان
        weight_orders = WeightClosingOrder.query.filter_by(valuation_journal_entry_id=entry.id).all()
        for wo in weight_orders:
            wo.valuation_journal_entry_id = None
        
        # 4. تنفيذات إقفال الأوزان
        weight_execs = WeightClosingExecution.query.filter_by(journal_entry_id=entry.id).all()
        for we in weight_execs:
            we.journal_entry_id = None
        
        # 5. معاملات الذهب مع الموردين
        supp_txns = SupplierGoldTransaction.query.filter_by(journal_entry_id=entry.id).all()
        for st in supp_txns:
            st.journal_entry_id = None
        
        # 6. دفعات الفواتير — InvoicePayment does not have journal_entry_id column; skip

        # 7. حذف SBTs المرتبطة بهذا القيد
        try:
            # SBTs created directly from this JE
            SafeBoxTransaction.query.filter_by(
                ref_type='journal_entry', ref_id=int(entry.id)
            ).delete(synchronize_session=False)
        except Exception:
            pass
        try:
            # If this is a voucher_reversal JE → orphan voucher_reversal SBTs
            if entry.reference_type == 'voucher_reversal' and entry.reference_id:
                SafeBoxTransaction.query.filter_by(
                    ref_type='voucher_reversal', ref_id=int(entry.reference_id)
                ).delete(synchronize_session=False)
        except Exception:
            pass
        try:
            # If this is a voucher JE being hard-deleted → remove its voucher SBTs
            if entry.reference_type == 'voucher' and entry.reference_id:
                SafeBoxTransaction.query.filter_by(
                    ref_type='voucher', ref_id=int(entry.reference_id)
                ).delete(synchronize_session=False)
        except Exception:
            pass

        # الآن حذف القيد نفسه
        db.session.delete(entry)
        db.session.commit()
        
        return jsonify({'result': 'success', 'message': 'تم الحذف النهائي للقيد'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'Failed to delete journal entry', 'detail': str(e)}), 500

