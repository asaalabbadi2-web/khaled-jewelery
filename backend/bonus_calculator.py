"""
خدمة حساب المكافآت للموظفين
===================================

توفر وظائف لحساب المكافآت بناءً على القواعد المحددة والبيانات المتاحة.

ملاحظة مهمة:
- حساب مكافآت الأرباح يعتمد على الفواتير المرحلة (Invoice.is_posted=True)
  وعلى الربح النقدي المحسوب: profit = total - total_tax - total_cost - commission_amount.
- عند وجود مكافأة معتمدة لنفس الفترة، يمكن إنشاء مكافأة إضافية (Incremental)
  للفواتير الجديدة فقط (profit_based + profit_percentage) بدون تعديل المكافأة المعتمدة.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import and_, func, or_

from models import (
    BonusInvoiceLink,
    BonusRule,
    Employee,
    EmployeeBonus,
    Invoice,
    db,
    get_race_points_config,
    get_race_points_per_gram,
)


# A rule's period, from what its form saves (bonus study م0, ث1). The scheduler
# runs each rule on its own period alone: it ran every rule daily, weekly and
# monthly, and the only rule on production -- monthly -- would have paid a
# week's 1,000 points again inside the month's. A rule without one is monthly.
_POINTS_PERIODS = {'today': 'daily', 'week': 'weekly', 'month': 'monthly'}
PERIODS = ('daily', 'weekly', 'monthly')


def rule_period(rule) -> str:
    if getattr(rule, 'period', None) in PERIODS:          # a tiered rule says it (م2)
        return rule.period
    conditions = rule.conditions or {}
    period = conditions.get('period') or _POINTS_PERIODS.get(conditions.get('points_period'))
    return period if period in PERIODS else 'monthly'


def _apply_limits(rule, raw_amount: float) -> tuple:
    """يُطبّق min_bonus / max_bonus ويُعيد (final_amount, min_applied, max_applied)."""
    amount = raw_amount
    min_applied = False
    max_applied = False
    if rule.min_bonus is not None and rule.min_bonus > 0 and amount < rule.min_bonus:
        amount = rule.min_bonus
        min_applied = True
    if rule.max_bonus is not None and rule.max_bonus > 0 and amount > rule.max_bonus:
        amount = rule.max_bonus
        max_applied = True
    return amount, min_applied, max_applied


def _rule_engine_points_source(rule) -> str | None:
    """Map BonusRule.points_source → engine mode, or None to inherit race settings.

    'gold'  → 'gold_weight'   (profit_gold × points_per_gram for all types)
    'cash'  → 'profit_cash'   (profit_cash ÷ cpp for بيع; profit_gold × ppg for شراء)
    None    → read from Settings.sales_race_settings (follow race exactly)
    """
    src = getattr(rule, 'points_source', None)
    if src == 'gold':
        return 'gold_weight'
    if src == 'cash':
        return 'profit_cash'
    return None  # caller resolves from race settings


def _formula_string(rule) -> str:
    """صيغة قابلة للقراءة تُحفظ في calculation_snapshot.calculation.formula."""
    v = rule.bonus_value
    rt, bt = rule.rule_type, rule.bonus_type
    if rt == 'tiered':
        tiers = '، '.join(f"من {t['from']:g}: " + (f"{t['per_unit']:g} لكل وحدة" if t.get('per_unit') is not None
                                                  else f"{t['amount']:g} ثابت") for t in (rule.tiers or []))
        return f'{rule.measure} للفترة {rule.period} → كله بسعر الشريحة التي بلغها ({tiers})'
    if rt == 'points_based' and bt == 'points_per_unit':
        src = getattr(rule, 'points_source', None)
        if src == 'cash':
            return f'profit_cash ÷ [settings.cash_amount_per_point] → employee_points × {v}'
        if src == 'gold':
            return f'profit_gold_g × [settings.points_per_gram] → employee_points × {v}'
        return f'[settings.points_source] formula → employee_points × {v}'
    templates = {
        ('sales_target',  'percentage'):        f'salary × {v}%',
        ('sales_target',  'fixed'):             f'ثابت: {v}',
        ('sales_target',  'sales_percentage'):  f'total_sales × {v}%',
        ('fixed',         'percentage'):        f'salary × {v}%',
        ('fixed',         'fixed'):             f'ثابت: {v}',
        ('profit_based',  'percentage'):        f'salary × {v}%',
        ('profit_based',  'fixed'):             f'ثابت: {v}',
        ('profit_based',  'profit_percentage'): f'target_profit × {v}%',
        ('points_based',  'fixed'):             f'ثابت: {v}',
        ('points_based',  'percentage'):        f'salary × {v}%',
    }
    return templates.get((rt, bt), f'{bt} × {v}')


class BonusCalculator:
    """حاسبة المكافآت للموظفين"""

    @staticmethod
    def calculate_tiered_bonus(employee, rule, period_start, period_end):
        """A tiered rule (bonus study م2): its measure for the employee over the
        period (the one measure, ADR-058), all of it at the tier it reached,
        then the rule's cap. Points are whole, as the race shows them."""
        from services.bonus_tiers import pays, tier_for
        from services.performance_measures import activity, measure, TYPES
        if not employee.id:
            return None
        value = measure(rule.measure, employee.id, period_start, period_end)
        if rule.measure == 'points':
            value = int(round(value))
        tier = tier_for(rule.tiers, value)
        if tier is None:
            return None
        raw_amount = pays(tier, value)
        amount, min_applied, max_applied = _apply_limits(rule, raw_amount)
        if amount <= 0:
            return None
        calculation_data = {
            'measure': rule.measure,
            'period': rule.period,
            'value': value,
            'tier': tier,
            'tiers': rule.tiers,
            'invoice_count': len(activity(employee.id, period_start, period_end, TYPES[rule.measure])),
        }
        if rule.measure == 'points':
            calculation_data['employee_points'] = value
        return raw_amount, amount, calculation_data, min_applied, max_applied

    @staticmethod
    def calculate_sales_bonus(employee, rule, period_start, period_end):
        """حساب مكافأة المبيعات (sales_target): المبيعات من المقياس الواحد -- للبائع،
        والمرتجع يأخذ نصيبه في فترته (bonus study م1)."""
        from services.performance_measures import measure
        if not employee.id:
            return None
        total_sales = measure('sales', employee.id, period_start, period_end)

        conditions = rule.conditions or {}
        sales_target = conditions.get("sales_target", 0)
        if total_sales < sales_target:
            return None

        raw_amount = 0.0
        if rule.bonus_type == "percentage":
            raw_amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == "fixed":
            raw_amount = rule.bonus_value
        elif rule.bonus_type == "sales_percentage":
            raw_amount = total_sales * (rule.bonus_value / 100)

        amount, min_applied, max_applied = _apply_limits(rule, raw_amount)

        calculation_data = {
            "sales_amount": total_sales,
            "sales_target": sales_target,
            "achievement_percentage": (total_sales / sales_target * 100) if sales_target > 0 else 0,
            "base_salary": employee.salary,
        }
        return raw_amount, amount, calculation_data, min_applied, max_applied

    @staticmethod
    def calculate_fixed_bonus(employee, rule, period_start, period_end):
        """حساب مكافأة ثابتة (fixed)."""
        raw_amount = 0.0
        if rule.bonus_type == "percentage":
            raw_amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == "fixed":
            raw_amount = rule.bonus_value

        amount, min_applied, max_applied = _apply_limits(rule, raw_amount)

        calculation_data = {"bonus_type": "fixed", "base_salary": employee.salary}
        return raw_amount, amount, calculation_data, min_applied, max_applied

    @staticmethod
    def calculate_profit_bonus(employee, rule, period_start, period_end):
        """حساب مكافأة الأرباح (profit_based): فواتير الموظف من المقياس الواحد -- للبائع،
        والمرتجع يأخذ نصيب أصله من الربح في فترته (bonus study م1)."""
        from points.engine import is_correction, is_return, returned_share
        from services.performance_measures import CUSTOMER_BUY, SALE, activity
        if not employee.id:
            return None

        applicable_types = rule.applicable_invoice_types
        types = tuple(applicable_types) if applicable_types else (SALE, CUSTOMER_BUY)
        activity_list = activity(employee.id, period_start, period_end, types)
        eligible_invoices = [i for i in activity_list if not is_return(i) and not is_correction(i)]
        returns = [i for i in activity_list if is_return(i)]

        # نحسب الربح لكل فاتورة بنفس منطق السباق (profit_gold = وزن العيار الرئيسي)
        # حتى لا تُسقط فاتورة بخسارة مكافأة الفترة بالكامل.

        conditions = rule.conditions or {}
        min_profit = conditions.get("min_profit", 0)
        profit_type = conditions.get("profit_type", "cash")

        # ── نوع الفواتير التي تُعتبر "مشتريات" في سباق الأداء ──
        # شراء من عميل فقط (كسر) — لا تشمل شراء المورد
        PURCHASE_TYPES = {'شراء من عميل'}

        profitable_invoice_ids = []
        profitable_per_invoice_profit = []
        total_profit_cash = 0.0
        total_profit_gold = 0.0

        for inv in eligible_invoices:
            # ─ ربح ذهب: نفس الحقل الذي يستخدمه السباق ─
            inv_profit_gold = float(inv.profit_gold or 0.0)

            # ─ ربح نقدي ─
            if inv.invoice_type in PURCHASE_TYPES:
                # للمشتريات: الربح الحقيقي هو وزن الذهب المُقتنى (inv_profit_gold).
                # لا ربح نقدي صافٍ للمشتريات.
                inv_profit_cash = 0.0
            else:
                total_value = float(inv.total or 0)
                tax_value = float(inv.total_tax or 0)
                cost_value = float(inv.total_cost or 0)
                commission = float(inv.commission_amount or 0)
                inv_profit_cash = total_value - tax_value - cost_value - commission

            # ─ اختر قيمة الربح حسب نوع القاعدة ─
            if profit_type == "gold":
                profit_val = inv_profit_gold
            elif profit_type == "cash":
                profit_val = inv_profit_cash
            else:
                # "both": وزن للمشتريات + نقد للمبيعات
                profit_val = inv_profit_gold if inv.invoice_type in PURCHASE_TYPES else inv_profit_cash

            if profit_val > 0:
                profitable_invoice_ids.append(inv.id)
                profitable_per_invoice_profit.append(profit_val)
                total_profit_cash += inv_profit_cash
                total_profit_gold += inv_profit_gold

        # A return takes back its original's profit, in the share it returns, in
        # its own period -- as the race takes its points back.
        for ret in returns:
            original = getattr(ret, 'original_invoice', None)
            if original is None:
                continue
            share = returned_share(ret, original)
            back_gold = float(original.profit_gold or 0.0) * share
            back_cash = 0.0 if original.invoice_type in PURCHASE_TYPES else share * (
                float(original.total or 0) - float(original.total_tax or 0)
                - float(original.total_cost or 0) - float(original.commission_amount or 0))
            if max(back_cash, back_gold) > 0:
                total_profit_cash -= max(back_cash, 0.0)
                total_profit_gold -= max(back_gold, 0.0)

        invoice_count = len(profitable_invoice_ids)
        if invoice_count == 0:
            return None

        invoice_ids = profitable_invoice_ids
        per_invoice_profit = profitable_per_invoice_profit

        if profit_type == "cash":
            target_profit = total_profit_cash
        elif profit_type == "gold":
            # نحوّل الجرام لنقاط باستخدام إعداد سباق الأداء الديناميكي
            points_per_gram = get_race_points_per_gram()
            target_profit = total_profit_gold * points_per_gram
        else:
            target_profit = total_profit_cash + total_profit_gold

        if target_profit <= 0 or target_profit < min_profit:
            return None

        raw_amount = 0.0
        if rule.bonus_type == "percentage":
            raw_amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == "fixed":
            raw_amount = rule.bonus_value
        elif rule.bonus_type == "profit_percentage":
            raw_amount = target_profit * (rule.bonus_value / 100)

        amount, min_applied, max_applied = _apply_limits(rule, raw_amount)

        calculation_data = {
            "total_profit_cash": total_profit_cash,
            "total_profit_gold": total_profit_gold,
            "target_profit": target_profit,
            "profit_type": profit_type,
            "points_per_gram": get_race_points_per_gram() if profit_type == "gold" else None,
            "invoice_count": invoice_count,
            "min_profit": min_profit,
            "base_salary": employee.salary,
            "applicable_invoice_types": applicable_types,
            "invoice_ids": invoice_ids,
            "per_invoice_profit": per_invoice_profit,
        }
        return raw_amount, amount, calculation_data, min_applied, max_applied

    @staticmethod
    def calculate_points_bonus(employee, rule, period_start, period_end):
        """حساب مكافأة النقاط (points_based) — يستهلك محرك سباق الأداء المشترك.

        لا تُوجد معادلة مستقلة هنا: points/engine.compute_invoices_points هو
        المصدر الوحيد للحقيقة، والإعدادات تُقرأ من Settings.sales_race_settings.
        """
        from datetime import date as _date
        from points.engine import compute_invoices_points

        conditions  = rule.conditions or {}
        points_period = conditions.get("points_period", "month")
        min_points  = float(conditions.get("min_points", 0))

        if isinstance(period_start, _date) and not isinstance(period_start, datetime):
            start_dt = datetime.combine(period_start, datetime.min.time())
        else:
            start_dt = period_start

        if isinstance(period_end, _date) and not isinstance(period_end, datetime):
            end_dt = datetime.combine(period_end, datetime.max.time())
        else:
            end_dt = period_end

        # The employee's own, from the one measure (bonus study م1): the seller,
        # else the poster -- it credited both -- with the returns and the
        # corrections of theirs made in the period (ADR-056).
        from services.performance_measures import activity
        invoices = activity(employee.id, start_dt, end_dt)

        # ── Resolve engine parameters from race settings (single source of truth) ──
        race_cfg            = get_race_points_config()
        engine_mode         = _rule_engine_points_source(rule)  # None → inherit settings
        points_source       = engine_mode or race_cfg['points_source']
        cash_amount_per_pt  = float(race_cfg['cash_amount_per_point'])
        points_per_gram     = float(race_cfg['points_per_gram'])
        point_rules         = race_cfg.get('point_rules') or []

        raw_pts = compute_invoices_points(
            invoices,
            points_source=points_source,
            cash_amount_per_point=cash_amount_per_pt,
            points_per_gram=points_per_gram,
            point_rules=point_rules,
        )
        employee_points = int(round(raw_pts))

        if employee_points < min_points:
            return None

        raw_amount = 0.0
        if rule.bonus_type == "points_per_unit":
            raw_amount = employee_points * rule.bonus_value
        elif rule.bonus_type == "fixed":
            raw_amount = rule.bonus_value
        elif rule.bonus_type == "percentage":
            raw_amount = employee.salary * (rule.bonus_value / 100)

        amount, min_applied, max_applied = _apply_limits(rule, raw_amount)

        if amount <= 0:
            return None

        calculation_data = {
            "points_source":       points_source,
            "cash_amount_per_pt":  cash_amount_per_pt,
            "points_per_gram":     points_per_gram,
            "raw_points_float":    round(raw_pts, 4),
            "employee_points":     employee_points,
            "points_period":       points_period,
            "min_points":          min_points,
            "bonus_type":          rule.bonus_type,
            "invoice_count":       len(invoices),
            "base_salary":         employee.salary,
        }
        return raw_amount, amount, calculation_data, min_applied, max_applied

    @staticmethod
    def _compute(employee, rule, period_start, period_end):
        """(raw, amount, data, min_applied, max_applied) by the rule's type, or None."""
        calculators = {
            'tiered': BonusCalculator.calculate_tiered_bonus,
            'sales_target': BonusCalculator.calculate_sales_bonus,
            'fixed': BonusCalculator.calculate_fixed_bonus,
            'profit_based': BonusCalculator.calculate_profit_bonus,
            'points_based': BonusCalculator.calculate_points_bonus,
        }
        calculate = calculators.get(rule.rule_type)
        # Only the days the period shares with the rule's validity count
        # (bonus study م3ج); the bonus stays the period's, and says them.
        window = rule.valid_window(period_start, period_end)
        if calculate is None or window is None:
            return None
        result = calculate(employee, rule, *window)
        if result and window != (period_start, period_end):
            result[2]['measured_from'], result[2]['measured_to'] = window[0].isoformat(), window[1].isoformat()
        return result

    @staticmethod
    def estimate(employee, rule, period_start, period_end) -> float:
        """What the rule would pay the employee for the period so far -- the
        amount a goal promises is what its bonus pays (bonus study م1). Nothing
        is written."""
        if not rule.is_active or not rule.applies_to(employee):
            return 0.0
        result = BonusCalculator._compute(employee, rule, period_start, period_end)
        return float(result[1]) if result else 0.0

    @staticmethod
    def calculate_bonus(employee, rule, period_start, period_end):
        """حساب المكافأة بناءً على نوع القاعدة."""
        if not rule.is_active or not rule.applies_to(employee):
            return None

        result = BonusCalculator._compute(employee, rule, period_start, period_end)
        if not result:
            return None

        raw_amount, amount, calculation_data, min_applied, max_applied = result

        calculation_snapshot = {
            "inputs": calculation_data,
            "calculation": {
                "rule_type": rule.rule_type,
                "formula": _formula_string(rule),
                "raw_amount": round(raw_amount, 4),
                "min_bonus_applied": min_applied,
                "max_bonus_applied": max_applied,
            },
            "result": {
                "final_bonus": round(amount, 4),
            },
        }

        bonus = EmployeeBonus(
            employee_id=employee.id,
            bonus_rule_id=rule.id,
            bonus_type=rule.rule_type,
            amount=amount,
            period_start=period_start,
            period_end=period_end,
            calculation_data=calculation_data,
            rule_snapshot=rule.to_snapshot(),
            calculation_snapshot=calculation_snapshot,
            status="pending",
            created_at=datetime.now(),
        )
        return bonus

    @staticmethod
    def calculate_all_bonuses_for_period(period_start, period_end, employee_ids=None, rule_ids=None, refresh_results=True,
                                         period_type=None):
        """
        الاحتساب التلقائي للمكافآت — Scheduler هو المصدر الوحيد لاستدعاء هذه الدالة.

        قواعد الحماية الصارمة:
          • مكافأة معتمدة (approved) أو مدفوعة (paid) → غير قابلة للإعادة. لا تُمس.
          • مكافأة مرفوضة (rejected) → قرار إداري معتمد. لا تُعاد.
          • مكافأة معلقة (pending) → يُعاد احتسابها (تحديث للمبلغ).
          • جميع المكافآت الجديدة تُنشأ بحالة pending دائماً.

        لا يوجد فلتر بحسب "نوع الفترة" (يومي/أسبوعي/شهري): BonusRule لا يحمل هذا
        المفهوم في أي عمود — القاعدة تُقيَّم بحرفية period_start/period_end التي
        يُمرّرها المستدعي، أيًّا كان نوعها. محاولة سابقة (٢٠٢٦-٠٥-٣١) افترضت عمود
        BonusRule.goal_period لم يوجد قط، فكانت كل استدعاءات المجدول (اليومي
        والأسبوعي والشهري) تتحطم بـ AttributeError منذ ذلك التاريخ — أربعة أشهر
        بلا احتساب تلقائي واحد ناجح. أُزيل الفلتر المعطوب بدل تعطيله شرطيًا: بناء
        حقل فترة حقيقي على BonusRule قرار منتج منفصل (migration + واجهة اختيار +
        سياسة القيم الافتراضية للقواعد القائمة)، لا إصلاح عطل.
        """
        bonuses = []
        processed_bonus_ids = []

        employees_query = Employee.query.filter_by(is_active=True)
        if employee_ids:
            employees_query = employees_query.filter(Employee.id.in_(employee_ids))
        employees = employees_query.all()

        rules_query = BonusRule.query.filter_by(is_active=True)
        if rule_ids:
            rules_query = rules_query.filter(BonusRule.id.in_(rule_ids))
        rules = rules_query.all()
        # A scheduled run applies the rules of its period alone (ث1); a manual
        # one names its dates and rules itself.
        if period_type is not None:
            rules = [rule for rule in rules if rule_period(rule) == period_type]

        def _sync_invoice_links(bonus_obj, invoice_ids):
            if invoice_ids is None:
                return
            BonusInvoiceLink.query.filter_by(bonus_id=bonus_obj.id).delete()
            for inv_id in invoice_ids:
                db.session.add(BonusInvoiceLink(bonus_id=bonus_obj.id, invoice_id=inv_id))

        def _linked_invoice_ids_for(employee_id, rule_id):
            bonus_ids = [
                b.id
                for b in EmployeeBonus.query.filter_by(
                    employee_id=employee_id,
                    bonus_rule_id=rule_id,
                    period_start=period_start,
                    period_end=period_end,
                ).all()
            ]
            if not bonus_ids:
                return set()
            links = BonusInvoiceLink.query.filter(BonusInvoiceLink.bonus_id.in_(bonus_ids)).all()
            return {l.invoice_id for l in links}

        for employee in employees:
            for rule in rules:
                existing_bonuses = EmployeeBonus.query.filter_by(
                    employee_id=employee.id,
                    bonus_rule_id=rule.id,
                    period_start=period_start,
                    period_end=period_end,
                ).all()

                # حماية غير قابلة للكسر: approved/paid لا تُعاد أبداً
                if any(b.status in ('approved', 'paid') for b in existing_bonuses):
                    for b in existing_bonuses:
                        processed_bonus_ids.append(b.id)
                        bonuses.append(b)
                    continue

                # قرار إداري: rejected لا تُعاد (تتطلب reversal ثم دورة جديدة)
                if existing_bonuses and any(b.status == 'rejected' for b in existing_bonuses):
                    for b in existing_bonuses:
                        processed_bonus_ids.append(b.id)
                        bonuses.append(b)
                    continue

                # pending متعددة: نحذف القديمة ونحتفظ بالأحدث
                if len(existing_bonuses) > 1:
                    existing_bonuses.sort(key=lambda x: x.id, reverse=True)
                    for old_bonus in existing_bonuses[1:]:
                        if old_bonus.status == 'pending':
                            db.session.delete(old_bonus)

                existing = existing_bonuses[0] if existing_bonuses else None
                bonus = BonusCalculator.calculate_bonus(employee, rule, period_start, period_end)
                if not bonus:
                    continue

                if existing:
                    # تحديث المكافأة المعلقة بالنتيجة الجديدة
                    existing.amount = bonus.amount
                    existing.calculation_data = bonus.calculation_data
                    existing.status = 'pending'

                    # A pending bonus carries the snapshot of what computed it
                    # (ث7): its amount followed the rule and its snapshot stayed
                    # the first. An approved or paid one is never here.
                    existing.rule_snapshot = bonus.rule_snapshot
                    existing.calculation_snapshot = bonus.calculation_snapshot

                    invoice_ids = bonus.calculation_data.get('invoice_ids') if bonus.calculation_data else None
                    if invoice_ids is not None:
                        _sync_invoice_links(existing, invoice_ids)

                    processed_bonus_ids.append(existing.id)
                    bonuses.append(existing)
                else:
                    db.session.add(bonus)
                    db.session.flush()

                    invoice_ids = bonus.calculation_data.get('invoice_ids') if bonus.calculation_data else None
                    if invoice_ids is not None:
                        _sync_invoice_links(bonus, invoice_ids)

                    processed_bonus_ids.append(bonus.id)
                    bonuses.append(bonus)

        try:
            db.session.commit()
        except Exception as e:
            db.session.rollback()
            print(f"خطأ في حساب المكافآت: {e}")
            return []

        if refresh_results and processed_bonus_ids:
            bonuses = (
                EmployeeBonus.query.filter(EmployeeBonus.id.in_(processed_bonus_ids))
                .order_by(EmployeeBonus.employee_id.asc(), EmployeeBonus.bonus_rule_id.asc().nullsfirst())
                .all()
            )

        return bonuses

    @staticmethod
    def calculate_bonus_for_invoice(invoice_id):
        """حساب مكافأة تلقائية لفاتورة واحدة (غير مستخدم افتراضياً في المسارات الحالية)."""
        invoice = Invoice.query.get(invoice_id)
        print(f"\n🔍 calculate_bonus_for_invoice called for invoice #{invoice_id}")

        if not invoice:
            print("   ❌ Invoice not found")
            return None

        # هذا المسار يتطلب employee_id على invoice (قد لا يكون متوفر في هذا المشروع)
        if not getattr(invoice, "employee_id", None):
            print("   ❌ No employee_id assigned to invoice")
            return None

        profit_cash = float(invoice.profit_cash) if invoice.profit_cash else 0.0
        if profit_cash <= 0:
            return None

        rules = BonusRule.query.filter_by(is_active=True, rule_type="profit_based").all()
        applicable_rules = []
        for rule in rules:
            if rule.target_employee_ids and invoice.employee_id not in rule.target_employee_ids:
                continue
            if rule.applicable_invoice_types and invoice.invoice_type not in rule.applicable_invoice_types:
                continue
            applicable_rules.append(rule)

        if not applicable_rules:
            return None

        rule = applicable_rules[0]
        bonus_percentage = rule.bonus_value
        bonus_amount = profit_cash * (bonus_percentage / 100.0)

        if rule.min_bonus is not None and rule.min_bonus > 0 and bonus_amount < rule.min_bonus:
            bonus_amount = rule.min_bonus
        if rule.max_bonus is not None and rule.max_bonus > 0 and bonus_amount > rule.max_bonus:
            bonus_amount = rule.max_bonus

        bonus = EmployeeBonus(
            employee_id=invoice.employee_id,
            bonus_rule_id=rule.id,
            amount=round(bonus_amount, 2),
            bonus_type="profit_based",
            period_start=invoice.date.date() if isinstance(invoice.date, datetime) else invoice.date,
            period_end=invoice.date.date() if isinstance(invoice.date, datetime) else invoice.date,
            status="pending",
            calculation_data={
                "invoice_id": invoice_id,
                "profit_cash": profit_cash,
                "bonus_percentage": bonus_percentage,
                "auto_calculated": True,
            },
        )

        db.session.add(bonus)
        db.session.flush()
        db.session.add(BonusInvoiceLink(bonus_id=bonus.id, invoice_id=invoice_id))
        db.session.commit()
        return bonus

    @staticmethod
    def get_employee_bonuses_summary(employee_id, start_date=None, end_date=None):
        query = EmployeeBonus.query.filter_by(employee_id=employee_id)
        if start_date:
            query = query.filter(EmployeeBonus.period_start >= start_date)
        if end_date:
            query = query.filter(EmployeeBonus.period_end <= end_date)

        bonuses = query.all()
        total_bonuses = sum(b.amount for b in bonuses if b.status in ["approved", "paid"])
        pending_bonuses = sum(b.amount for b in bonuses if b.status == "pending")
        paid_bonuses = sum(b.amount for b in bonuses if b.status == "paid")

        return {
            "total_bonuses": total_bonuses,
            "pending_bonuses": pending_bonuses,
            "paid_bonuses": paid_bonuses,
            "bonuses_count": len(bonuses),
            "bonuses": [b.to_dict(include_employee=False, include_rule=True) for b in bonuses],
        }


# ──────────────────────────────────────────────────────────────────────────────
# Private helpers
# ──────────────────────────────────────────────────────────────────────────────

def _bonus_type_label(bonus_type: str) -> str:
    return {
        'sales_target': 'هدف المبيعات',
        'attendance': 'مكافأة الحضور',
        'performance': 'مكافأة الأداء',
        'fixed': 'مكافأة ثابتة',
        'profit_based': 'مكافأة الأرباح',
        'goal_achieved': 'تحقيق هدف',
        'custom': 'مكافأة خاصة',
    }.get(bonus_type, 'مكافأة معتمدة')

