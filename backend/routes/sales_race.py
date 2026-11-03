"""The sales race's settings and the home screen's leaderboard (REPORTS ت0-2, ADR-083).

Moved from routes/reports.py as they were: they are not reports. Registered
under /api in app.py; their URLs are unchanged.
"""
from __future__ import annotations

import json
from datetime import date, datetime, timedelta

from flask import Blueprint, g, jsonify, request

from auth_decorators import require_permission
from core.settings import _get_settings_singleton
from models import Employee, Invoice, db

sales_race_bp = Blueprint('sales_race', __name__)


@sales_race_bp.route('/sales-race/config', methods=['GET'])
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

@sales_race_bp.route('/sales-race/config/preview', methods=['POST'])
@require_permission('system.settings')
def preview_sales_race_config():
    """What a change of the race's points settings does to the open period
    (bonus study م3د; the owner: «حيّ مع تحذير ومعاينة»): the settings are
    read live, so the change measures the whole period gone so far. Body: any
    of points_source, cash_amount_per_point, points_per_gram,
    points_per_invoice. Says each employee's points this month now and with
    them, and what each open points rule pays now and with them. Writes
    nothing."""
    from bonus_calculator import _apply_limits
    from models import BonusRule
    from services.bonus_tiers import pays, tier_for
    from services.performance_measures import POINTS_SETTINGS, measure
    data = request.get_json(silent=True) or {}
    proposed = {}
    for key in POINTS_SETTINGS:
        if key not in data:
            continue
        if key == 'points_source':
            if data[key] not in {'gold_weight', 'profit_cash', 'sales_amount', 'invoice_count', 'sold_weight'}:
                proposed = None
                break
            proposed[key] = data[key]
            continue
        try:
            proposed[key] = float(data[key])
        except (TypeError, ValueError):
            proposed = None
            break
    if proposed is None:
        return jsonify({'success': False, 'error': 'invalid_race_settings',
                        'message': 'إعداد النقاط غير مقروء: المصدر من القائمة، والقيم أرقام'}), 400

    today = date.today()
    month = (today.replace(day=1), today)
    open_periods = {'daily': (today, today), 'weekly': (today - timedelta(days=today.weekday()), today),
                    'monthly': month}
    employees = Employee.query.filter_by(is_active=True).order_by(Employee.name).all()

    def points(emp, window, settings):
        return int(round(measure('points', emp.id, *window, points=settings)))

    rows = []
    for emp in employees:
        now, new = points(emp, month, None), points(emp, month, proposed)
        if now or new:
            rows.append({'employee_id': emp.id, 'employee': emp.name, 'points_now': now, 'points_new': new})
    rules = []
    for rule in BonusRule.query.filter_by(is_active=True, rule_type='tiered', measure='points').order_by(BonusRule.id):
        window = rule.valid_window(*open_periods.get(rule.period or 'monthly', month))
        if window is None:
            continue
        for emp in employees:
            if not rule.applies_to(emp):
                continue
            amounts = []
            for settings in (None, proposed):
                value = points(emp, window, settings)
                tier = tier_for(rule.tiers, value)
                amounts.append(round(_apply_limits(rule, pays(tier, value))[0], 2) if tier is not None else 0.0)
            if any(amounts):
                rules.append({'rule_id': rule.id, 'rule': rule.name, 'employee_id': emp.id, 'employee': emp.name,
                              'period': rule.period or 'monthly', 'amount_now': amounts[0], 'amount_new': amounts[1]})
    return jsonify({'success': True, 'period_start': month[0].isoformat(), 'period_end': today.isoformat(),
                    'employees': rows, 'rules': rules}), 200


@sales_race_bp.route('/sales-race/config', methods=['PUT'])
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

@sales_race_bp.route('/home/leaderboard', methods=['GET'])
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
    from services.race_visibility import race_visibility

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

    # Who sees what: one reading for the race and «هدفي» (bonus study م3ي).
    _vis = race_visibility(_lb_user, period, sales_race_config)
    _can_view_admin = _vis['admin']
    can_view_amounts = _vis['amounts']
    can_view_points = _vis['points']
    can_view_share = _vis['share']
    can_view_team_summary = _vis['team_summary']

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

    metric_obj.period = (start_dt, end_dt)   # its corrections (ADR-056), where the metric reads them
    ranking_raw, _metric_aux = metric_obj.collect(base_filters, points_per_gram)
    metric_key = metric_obj.key

    for it in ranking_raw:
        it['score'] = metric_obj.extract_score(it)

    ranking_raw.sort(key=lambda x: (x.get('score', 0.0), x.get('count', 0)), reverse=True)

    # A share is of what was earned: a row below nothing has none.
    total_score = sum(max(0.0, float(it.get('score') or 0.0)) for it in ranking_raw) or 0.0

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
        share = (max(0.0, score_value) / total_score) if total_score > 0 else 0.0

        # تقدم الهدف — خاص بالفترة المعروضة فقط، بدون نسبة مقيّدة بـ 1.0
        goal_target = None
        goal_progress = None
        if _goal_attr:
            emp = _emp_by_id.get(it['id'])
            if emp:
                # The goal's one target (ADR-058): a goal paid by a rule aims
                # at the rule's threshold, not the employee's number beside it.
                from services.goal_achievements import goal_target as _goal_target
                raw_t = _goal_target(emp, {'today': 'daily', 'week': 'weekly', 'month': 'monthly'}[period],
                                     {'count': 'invoices'}.get(metric, metric))
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

    # The months each led and the goal periods each reached, as kept when
    # their periods closed (bonus study م3هـ).
    from services.race_honours import honours_of
    _honours = honours_of([r['id'] for r in ranking if int(r['id'] or 0) > 0])
    for r in ranking:
        r.update(_honours.get(r['id'], {'crowns': 0, 'goals_reached': 0}))

    # Recompute after visibility filtering so total always = sum of displayed cards --
    # a row below nothing too: its loss comes off the team's (POINTS-DEFICIT-1).
    _display_total_points = sum(int(r.get('score', 0) or 0) for r in ranking)

    champion = None
    if ranking and bool(sales_race_config.get('show_champion', True)):
        champion = {
            'id': ranking[0]['id'],
            'name': ranking[0]['name'],
            'badge': '🥇',
        }

    # The team's monthly goal: its employees' monthly goals summed, by the one
    # measure (bonus study م3ح) -- whatever period the race shows. It was a
    # weight in the settings turned into points by the points per gram.
    # Shown in the month's view alone (the owner: the employee opens the month
    # to see where they are), to whom the team summary is shown.
    # The week's: the settings' weekly target in grams (the owner: «الهدف
    # الأسبوعي للفريق من الإعدادات»). None in the day's view.
    from services.goal_achievements import team_goal as _team_goal, team_week_goal as _team_week_goal
    # Everyone sees it (the owner: «الجميع دائمًا») -- a goal in points or
    # grams, not the team summary's money; hidden only where its points are.
    team_goal = None
    if period == 'month':
        team_goal = _team_goal(date.today())
    elif period == 'week':
        team_goal = _team_week_goal(date.today())
    if team_goal is not None and team_goal['metric'] == 'points' and not can_view_points:
        team_goal = None

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
        'team_goal': team_goal,
    }

    # Admin summary visibility is controlled by team_summary_visibility setting.
    # Profit is always admin-only regardless of settings.
    can_view_total_cash = can_view_team_summary
    can_view_total_profit = _can_view_admin

    if can_view_total_cash or can_view_total_profit:
        # Aggregate across posted sales and purchases for the same period. The
        # sales are net of their returns in it -- as each seller's card takes a
        # return back (ADR-041), so the card is the sum of the cards beneath it
        # (it left 2,221 of October's returns in, 20 Oct 2026).
        totals = (
            db.session.query(
                func.coalesce(
                    func.sum(case((Invoice.invoice_type == 'بيع', Invoice.total),
                                  (Invoice.invoice_type == 'مرتجع بيع', -Invoice.total), else_=0.0)),
                    0.0,
                ).label('sales_total'),
                func.coalesce(
                    func.sum(case((Invoice.invoice_type == 'شراء من عميل', Invoice.total),
                                  (Invoice.invoice_type == 'مرتجع شراء', -Invoice.total), else_=0.0)),
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
                Invoice.invoice_type.in_(['بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء']),
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
