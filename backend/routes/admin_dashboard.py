"""The manager's dashboard and where the business stands (DASH-3..11; REPORTS ت0-2, ADR-083).

Moved from routes/reports.py as they were: a dashboard is not a report.
Registered under /api in app.py; their URLs are unchanged.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from flask import Blueprint, current_app, jsonify
from sqlalchemy import or_

from auth_decorators import require_permission
from core.database import _db_has_column
from models import Employee, InvoiceItem, SafeBox, db
from pricing.karat_service import get_main_karat
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
      health     the scheduler alive, the nightly check's last run, the
                 server's newest backup (15 Nov 2026)
      net_position  what the shop has less what it owes, each side by the
                 readers above and the safes (services/dashboard_net) -- the
                 head's figure (15 Nov 2026)
      upcoming   what the shop will pay soon: the period expenses, the
                 salaries, the suppliers, the VAT (15 Nov 2026) -- after the
                 positions and the VAT, whose figures it says
    """
    from services.dashboard_alerts import alerts
    from services.dashboard_approvals import approvals
    from services.dashboard_clearing import clearing_pending
    from services.dashboard_deficits import deficits
    from services.dashboard_health import health
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
        'health': lambda: health(datetime.utcnow()),
    }
    from services.dashboard_net import net_position
    from services.dashboard_upcoming import upcoming
    sections['upcoming'] = lambda: upcoming(
        now.date(), suppliers=(out.get('positions') or {}).get('suppliers'),
        vat_owed=(out.get('vat') or {}).get('owed') if out.get('vat') is not None else None)
    # last: it says the others' figures, and is not read when one of them is not
    sections['net_position'] = lambda: net_position(positions=out.get('positions'), clearing=out.get('clearing'),
                                                    upcoming=out.get('upcoming'))
    out = {}
    for name, read in sections.items():
        try:
            out[name] = read()
        except Exception:
            db.session.rollback()
            current_app.logger.exception('dashboard standing: %s could not be read', name)
            out[name] = None
    return jsonify(out), 200


@admin_dashboard_bp.route('/dashboard/admin', methods=['GET'])
@require_permission('dashboard.admin')   # the manager's alone (DASH-3, the owner 30 Oct 2026)
def get_admin_dashboard():
    """The manager's dashboard: the gold and the cash where they are, and the
    period's activity beside the one before it (the owner, 15 Nov 2026:
    «اطلع على لوحة تحكم المدير وحللها ... ابدأ بالبند ١ وطبق جميع ما اقترحت»).

      global_snapshot  the price the gold is valued at, and when -- the net
                       position is the standing's (services/dashboard_net):
                       what is owed is read there
      kpis             the gold by karat and in the main karat; the cash
      liquidity        the safes and the banks (the standing adds what is on its way)
      safe_boxes       every active safe, its balance
      sales_purchases_summary  today, the month and the year -- each with
                       `previous`: the period before it to the same point
                       (yesterday to this hour, last month to this day, last
                       year to this date), by the same readers
      series.daily     the last seven days' sales and scrap bought, by them too
      unavailable      what could not be read: the screen says «غير متاح»,
                       never a zero. Each failure is logged.

    Where the business stands is its own request, /dashboard/admin/standing
    (DASH-10). What was computed and never shown -- today's «profit» (sales
    less purchases), yesterday's, the margins, the average cost, the price's
    change, the inventory value -- is gone with its sums.
    """
    from models import GoldPrice, Invoice, SafeBoxTransaction

    now = datetime.now()
    today_start = datetime.combine(now.date(), datetime.min.time())
    main_karat = get_main_karat()
    unavailable = []

    def failed(section):
        current_app.logger.exception('admin dashboard: %s could not be read', section)
        db.session.rollback()
        unavailable.append(section)

    # --- The price the gold is valued at, and when it was saved ---
    spot_price_24k_per_gram = spot_price_timestamp = None
    try:
        latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        if latest and latest.price:
            from pricing.office_price import row_gram_price
            spot_price_24k_per_gram = row_gram_price(latest, 24)   # the office's (OFFICE-PRICE-1)
            spot_price_timestamp = latest.date.isoformat() if latest.date else None
    except Exception:
        failed('valuation')

    # --- The safes: the same reader as /safe-boxes/balances ---
    safe_boxes_summary = []
    safes_read = True
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
                'balance_gold_21k': weight.get('21k', 0.0),
                'weight_balance': {k: v for k, v in weight.items() if k != 'total'},
                'total_weight_main_karat': weight.get('total', 0.0),
                'main_karat': int(main_karat),
            })
    except Exception:
        failed('safes')
        safe_boxes_summary = []
        safes_read = False

    # --- What the safes hold, summed: nothing when they were not read ---
    cash_balance = cash_in_hand = cash_in_banks = None
    gold = None
    if safes_read:
        cash_balance = cash_in_hand = cash_in_banks = 0.0
        gold = dict.fromkeys(('18k', '21k', '22k', '24k'), 0.0)
        for sb in safe_boxes_summary:
            st = (sb.get('safe_type') or '').strip()
            if st in ('cash', 'bank', 'check'):
                cash_balance += float(sb.get('balance_cash') or 0.0)
            if st == 'cash':
                cash_in_hand += float(sb.get('balance_cash') or 0.0)
            elif st == 'bank':
                cash_in_banks += float(sb.get('balance_cash') or 0.0)
            if st == 'gold':
                wb = sb.get('weight_balance') if isinstance(sb.get('weight_balance'), dict) else {}
                for k in gold:
                    gold[k] += float(wb.get(k) or 0.0)
    gold_pure_24k = gold_equivalent_main_karat = None
    if gold is not None:
        gold_pure_24k = sum(gold[k] * int(k[:-1]) / 24.0 for k in gold)
        gold_equivalent_main_karat = sum(gold[k] * int(k[:-1]) / float(main_karat) for k in gold)
    # --- A safe that moved in the last 15 minutes pulses ---
    fifteen_mins_ago = now - timedelta(minutes=15)
    try:
        moved = {sid for (sid,) in db.session.query(SafeBoxTransaction.safe_box_id)
                 .filter(SafeBoxTransaction.created_at >= fifteen_mins_ago).distinct()}
        for sb_data in safe_boxes_summary:
            sb_data['has_recent_activity'] = sb_data['id'] in moved
    except Exception:
        failed('safe_activity')

    # --- The periods' activity, and the period before each ---
    sale_types = {'بيع': 1, 'sell': 1, 'sale': 1, 'مرتجع بيع': -1}
    sales_purchases_summary = {}
    daily = []
    try:
        from models import JournalEntryLine as JELine, JournalEntry as JE2, Account as AccModel

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
            except Exception:
                raise

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
                raise

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
            """The revenues the gram profit counts (ADR-092: every revenue but trading and the excluded) --
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
                raise

        def summary(p_start, p_end):
            return {
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

        def totals(block):
            return {k: {'total_value': v.get('total_value', 0.0), 'total_weight': v.get('total_weight', 0.0),
                        'docs': v.get('docs', 0)} for k, v in block.items()}

        for period_key, ((p_start, p_end), (q_start, q_end)) in previous_periods(now).items():
            try:
                block = summary(p_start, p_end)
                block['previous'] = totals(summary(q_start, q_end))
                block['previous_range'] = {'start': q_start.isoformat(), 'end': q_end.isoformat()}
                sales_purchases_summary[period_key] = block
            except Exception:
                failed(f'summary_{period_key}')

        try:
            for i in range(6, -1, -1):
                d_start = today_start - timedelta(days=i)
                d_end = d_start + timedelta(days=1)
                daily.append({
                    'day': d_start.date().isoformat(),
                    'sales': round(_build_inv_summary(sale_types, d_start, d_end)['total_value'], 2),
                    'scrap_customers': round(_build_inv_summary({'شراء من عميل': 1, 'مرتجع شراء': -1}, d_start,
                                                                d_end)['total_value'], 2),
                })
        except Exception:
            failed('daily')
            daily = []
    except Exception:
        failed('summary')

    def money(v):
        return None if v is None else round(v, 2)

    return jsonify({
        'success': True,
        'generated_at': now.isoformat(),
        'unavailable': unavailable,
        'global_snapshot': {
            'gold_price_24k': money(float(spot_price_24k_per_gram)) if spot_price_24k_per_gram else None,
            'gold_price_timestamp': spot_price_timestamp,
        },
        'kpis': {
            'cash_balance': money(cash_balance),
            'gold_by_karat': None if gold is None else {k: round(v, 3) for k, v in gold.items()},
            'gold_pure_24k': None if gold_pure_24k is None else round(gold_pure_24k, 3),
            'gold_equivalent_main_karat': None if gold_equivalent_main_karat is None
            else round(gold_equivalent_main_karat, 3),
            'main_karat': main_karat,
        },
        'series': {'daily': daily},
        'valuation': {
            'spot_price_24k_per_gram': money(float(spot_price_24k_per_gram)) if spot_price_24k_per_gram else None,
            'spot_price_timestamp': spot_price_timestamp,
            'currency': 'ر.س',
        },
        'liquidity': {
            'cash_available': money(cash_balance),
            'cash_in_hand': money(cash_in_hand),
            'cash_in_banks': money(cash_in_banks),
        },
        'safe_boxes': safe_boxes_summary,
        'sales_purchases_summary': sales_purchases_summary,
    }), 200


def previous_periods(now: datetime) -> dict:
    """{period: ((its start, its end), (the one before's start, end))}: today
    against yesterday to this hour, the month against the last one to this
    day (its last day when shorter), the year against the last one to this
    date -- each pair to the same point, so they compare (15 Nov 2026)."""
    import calendar
    today_start = datetime.combine(now.date(), datetime.min.time())
    tomorrow_start = today_start + timedelta(days=1)
    month_start = datetime(now.year, now.month, 1)
    last_month_end_day = month_start - timedelta(days=1)
    last_month_start = datetime(last_month_end_day.year, last_month_end_day.month, 1)
    same_day = min(now.day, calendar.monthrange(last_month_start.year, last_month_start.month)[1])
    year_start = datetime(now.year, 1, 1)
    last_year_day = min(now.day, calendar.monthrange(now.year - 1, now.month)[1])
    return {
        'today': ((today_start, tomorrow_start), (today_start - timedelta(days=1), now - timedelta(days=1))),
        'month': ((month_start, tomorrow_start),
                  (last_month_start, datetime(last_month_start.year, last_month_start.month, same_day)
                   + timedelta(days=1))),
        'year': ((year_start, tomorrow_start),
                 (datetime(now.year - 1, 1, 1), datetime(now.year - 1, now.month, last_year_day) + timedelta(days=1))),
    }
