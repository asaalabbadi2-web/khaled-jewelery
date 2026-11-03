"""The manager's dashboard and where the business stands (DASH-3..11; REPORTS ت0-2, ADR-083).

Moved from routes/reports.py as they were: a dashboard is not a report.
Registered under /api in app.py; their URLs are unchanged.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from flask import Blueprint, jsonify
from sqlalchemy import or_

from auth_decorators import require_permission
from core.database import _db_has_column
from models import Employee, InvoiceItem, SafeBox, db
from pricing.karat_service import get_main_karat, line_karat
from services.live_balances import safe_box_balances_bulk

admin_dashboard_bp = Blueprint('admin_dashboard', __name__)


@admin_dashboard_bp.route('/dashboard/admin/standing', methods=['GET'])
@require_permission('dashboard.admin')
def get_admin_dashboard_standing():
    """Where the business stands, beside the dashboard (DASH-10).

    The owner, 30 Oct 2026: «الشاشة أصبحت تأخذ وقتًا طويلًا في التحميل». The
    six readers DASH-4..9 added were summed onto the dashboard's one request,
    and the screen waited for all of it: they are their own request now, asked
    beside it, so the two take the longer one's time and the screen draws as
    soon as the dashboard's own arrives. Each section by its own reader; one
    that fails is null, and the others stand.

      positions  what is ours and what we owe (DASH-4)
      clearing   what the banks and the instalment companies owe us (DASH-5)
      approvals  what waits for the manager (DASH-6)
      wrong_now  the open findings and a safe below zero (DASH-7)
      vat        this quarter, the last one, what is owed (DASH-8)
      deficits   the month's losing invoices by employee (DASH-9)
    """
    from services.dashboard_alerts import alerts
    from services.dashboard_approvals import approvals
    from services.dashboard_clearing import clearing_pending
    from services.dashboard_deficits import deficits
    from services.dashboard_positions import positions
    from services.dashboard_vat import vat_due

    now = datetime.now()

    def safe_rows():
        safes = SafeBox.query.filter(SafeBox.is_active.is_(True)).all()
        balances = safe_box_balances_bulk(safes, main_karat=get_main_karat())
        return [{'name': sb.name, 'balance_cash': (balances.get(sb.id) or {}).get('cash', 0.0),
                 'total_weight_main_karat': ((balances.get(sb.id) or {}).get('weight') or {}).get('total', 0.0)}
                for sb in safes]

    sections = {
        'positions': positions,
        'clearing': lambda: clearing_pending(now),
        'approvals': approvals,
        'wrong_now': lambda: alerts(safe_rows(), today=now.date()),   # + documents near their end (EMP-3)
        'vat': lambda: vat_due(now.date()),
        'deficits': lambda: deficits(datetime(now.year, now.month, 1), now + timedelta(seconds=1)),
    }
    out = {}
    for name, read in sections.items():
        try:
            out[name] = read()
        except Exception as err:
            db.session.rollback()
            print(f'[dashboard standing] {name} error: {err}')
            out[name] = None
    return jsonify(out), 200


@admin_dashboard_bp.route('/dashboard/admin', methods=['GET'])
@require_permission('dashboard.admin')   # the manager's alone (DASH-3, the owner 30 Oct 2026)
def get_admin_dashboard():
    """Admin dashboard aggregates for KPIs and charts.

    Response shape (stable contract for Flutter):
      - kpis: cash_balance, gold_by_karat, gold_pure_24k, sales_today
      - series: last_7_days_sales (net_value/net_weight per day)
      - where the business stands is its own request, /dashboard/admin/standing
        (DASH-10). The old alerts -- the critical
        bar, the last shift's differences, the sensitive operations -- went
        from the screen on 2 Jun 2026 (448e4758) and from here on 30 Oct (the
        owner: «حذف بقايا الخادم القديمة»).
    """
    from models import SafeBox, SafeBoxTransaction, Invoice, GoldPrice

    now = datetime.now()
    today_start = datetime.combine(now.date(), datetime.min.time())
    tomorrow_start = today_start + timedelta(days=1)

    # --- Safe boxes summary (Account-derived balances; aligned with SafeBox details UI) ---
    main_karat = get_main_karat()
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
            from pricing.office_price import row_gram_price
            spot_price_24k_per_gram = row_gram_price(latest, 24)   # the office's (OFFICE-PRICE-1)
            spot_price_timestamp = latest.date.isoformat() if latest.date else None
    except Exception:
        spot_price_24k_per_gram = None
        spot_price_timestamp = None

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
        mk = float(main_karat)
        gold_equivalent_main_karat = (
            (gold_18k * (18.0 / mk))
            + (gold_21k * (21.0 / mk))
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
            item_karat = line_karat(item.karat, f'صنف {item.id}')
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
                'main_karat': int(main_karat),
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

    # Valued once the pure grams are known (NAMES-1: it was valued before
    # them, failed on the name, and was always empty).
    inventory_value = None
    if spot_price_24k_per_gram is not None:
        inventory_value = float(gold_pure_24k) * float(spot_price_24k_per_gram)

    try:
        mk = float(main_karat)
        gold_equivalent_main_karat = (
            (gold_18k * (18.0 / mk))
            + (gold_21k * (21.0 / mk))
            + (gold_22k * (22.0 / mk))
            + (gold_24k * (24.0 / mk))
        )
    except Exception:
        gold_equivalent_main_karat = 0.0

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
            from pricing.office_price import row_gram_price
            yesterday_spot = row_gram_price(yesterday_price, 24)
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

        def _build_inv_summary(inv_types_dict, start, end, exclude_gold_type=None, where=None):
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

                if where is not None:
                    q = q.filter(where)

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
            """The period's operating expenses, as the chart names them: group 5
            without the 51 subtree (cost of sales -- wages, scrap purchases, the
            cost of gold sold), net of reversals, by the one definition of a line
            that counts (the owner, 11 Oct 2026). It summed the debits of every
            5-account: 18,995,723.96 for the year against ~777,000 of operating
            expense -- and the dashboard took sales - purchases - that for profit."""
            try:
                from accounting.balances import counted_line_filters
                from services.income_accounts import operating_expense_account_ids
                ids = operating_expense_account_ids()
                if not ids:
                    return {'total_value': 0.0, 'by_account': [], 'docs': 0}
                # The entries that make them -- the tab's count, as the other tabs'
                # invoices (12 Oct 2026: the tab read empty, no count was sent).
                docs = (
                    db.session.query(db.func.count(db.func.distinct(JE2.id)))
                    .join(JELine, JELine.journal_entry_id == JE2.id)
                    .filter(JELine.account_id.in_(ids))
                    .filter(*counted_line_filters())
                    .filter(JE2.date >= start)
                    .filter(JE2.date < end)
                    .scalar()
                ) or 0
                rows = (
                    db.session.query(AccModel.id, AccModel.name, AccModel.account_number,
                                     db.func.coalesce(db.func.sum(JELine.cash_debit), 0.0)
                                     - db.func.coalesce(db.func.sum(JELine.cash_credit), 0.0))
                    .join(JELine, JELine.account_id == AccModel.id)
                    .join(JE2, JELine.journal_entry_id == JE2.id)
                    .filter(AccModel.id.in_(ids))
                    .filter(*counted_line_filters())
                    .filter(JE2.date >= start)
                    .filter(JE2.date < end)
                    .group_by(AccModel.id, AccModel.name, AccModel.account_number)
                    .all()
                )
                by_account = [
                    {'account': (name or number or '?').strip(), 'value': round(float(net or 0.0), 2)}
                    for _id, name, number, net in rows if abs(float(net or 0.0)) >= 0.005
                ]
                # Its grams too: the weight twins' lines (DASH-3, the owner 30 Oct 2026).
                weight, weight_by = _grams_of(ids, start, end)
                for a in by_account:
                    a['weight'] = weight_by.get(a['account'], 0.0)
                for name, grams in weight_by.items():
                    if not any(a['account'] == name for a in by_account):
                        by_account.append({'account': name, 'value': 0.0, 'weight': grams})
                return {
                    'total_value': round(sum(a['value'] for a in by_account), 2),
                    'total_weight': weight,
                    'by_account': sorted(by_account, key=lambda x: -x['value']),
                    'docs': int(docs),
                }
            except Exception:
                return {'total_value': 0.0, 'total_weight': 0.0, 'by_account': [], 'docs': 0}

        def _grams_of(account_ids, start, end, *, credit_side=False):
            """(main-karat grams, {account name: grams}) the weight lines of
            *account_ids* and their weight twins carry in the period (DASH-3) --
            an expense's debits, a revenue's credits, net of their reversals."""
            from accounting.balances import counted_line_filters
            from pricing.gold_price_service import get_main_karat
            if not account_ids:
                return 0.0, {}
            main = float(get_main_karat())
            owner_of = {}
            for acc in AccModel.query.filter(AccModel.id.in_(list(account_ids))).all():
                owner_of[acc.id] = acc
                if acc.memo_account_id:
                    owner_of[int(acc.memo_account_id)] = acc
            grams = sum(
                (getattr(JELine, f'debit_{k}k') - getattr(JELine, f'credit_{k}k')) * (k / main)
                for k in (18, 21, 22, 24))
            rows = (
                db.session.query(JELine.account_id, db.func.coalesce(db.func.sum(grams), 0.0))
                .join(JE2, JELine.journal_entry_id == JE2.id)
                .filter(JELine.account_id.in_(list(owner_of)))
                .filter(*counted_line_filters())
                .filter(JE2.date >= start)
                .filter(JE2.date < end)
                .group_by(JELine.account_id)
                .all()
            )
            by_owner = {}
            for account_id, net in rows:
                value = float(net or 0.0) * (-1.0 if credit_side else 1.0)
                owner = owner_of.get(int(account_id))
                name = ((owner.name if owner else None) or '?').strip()
                by_owner[name] = by_owner.get(name, 0.0) + value
            return round(sum(by_owner.values()), 3), {k: round(v, 3) for k, v in by_owner.items() if abs(v) >= 0.0005}

        def _build_revenues_summary(start, end):
            """The revenues the gram profit counts -- the owner's marks (ADR-048) --
            in riyals and in grams (DASH-3, the owner 30 Oct 2026)."""
            try:
                from accounting.balances import counted_line_filters
                from services.gram_profit_accounts import gram_profit_accounts
                ids, _ = gram_profit_accounts()
                if not ids:
                    return {'total_value': 0.0, 'total_weight': 0.0, 'by_account': [], 'docs': 0}
                docs = (
                    db.session.query(db.func.count(db.func.distinct(JE2.id)))
                    .join(JELine, JELine.journal_entry_id == JE2.id)
                    .filter(JELine.account_id.in_(list(ids)))
                    .filter(*counted_line_filters())
                    .filter(JE2.date >= start)
                    .filter(JE2.date < end)
                    .scalar()
                ) or 0
                rows = (
                    db.session.query(AccModel.name, AccModel.account_number,
                                     db.func.coalesce(db.func.sum(JELine.cash_credit), 0.0)
                                     - db.func.coalesce(db.func.sum(JELine.cash_debit), 0.0))
                    .join(JELine, JELine.account_id == AccModel.id)
                    .join(JE2, JELine.journal_entry_id == JE2.id)
                    .filter(AccModel.id.in_(list(ids)))
                    .filter(*counted_line_filters())
                    .filter(JE2.date >= start)
                    .filter(JE2.date < end)
                    .group_by(AccModel.name, AccModel.account_number)
                    .all()
                )
                weight, weight_by = _grams_of(ids, start, end, credit_side=True)
                by_account = [{'account': (name or number or '?').strip(), 'value': round(float(net or 0.0), 2)}
                              for name, number, net in rows if abs(float(net or 0.0)) >= 0.005]
                for a in by_account:
                    a['weight'] = weight_by.get(a['account'], 0.0)
                return {
                    'total_value': round(sum(a['value'] for a in by_account), 2),
                    'total_weight': weight,
                    'by_account': sorted(by_account, key=lambda x: -x['value']),
                    'docs': int(docs),
                }
            except Exception:
                return {'total_value': 0.0, 'total_weight': 0.0, 'by_account': [], 'docs': 0}

        for period_key, (p_start, p_end) in _summary_periods.items():
            try:
                sales_purchases_summary[period_key] = {
                    'sales': _build_inv_summary(sale_types, p_start, p_end),
                    # Three purchases, apart (DASH-3, the owner 30 Oct 2026): a
                    # supplier's, a customer's scrap, an office's settlement.
                    'purchases': _build_inv_summary({'شراء': 1, 'مرتجع شراء (مورد)': -1}, p_start, p_end,
                                                    where=Invoice.office_id.is_(None)),
                    'scrap_customers': _build_inv_summary({'شراء من عميل': 1, 'مرتجع شراء': -1}, p_start, p_end),
                    'office_settlements': _build_inv_summary({'شراء': 1}, p_start, p_end,
                                                             where=Invoice.office_id.isnot(None)),
                    'expenses': _build_expenses_summary(p_start, p_end),
                    'revenues': _build_revenues_summary(p_start, p_end),
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
        },
        'safe_boxes': safe_boxes_enhanced,
        'sales_purchases_summary': sales_purchases_summary,
    }), 200
