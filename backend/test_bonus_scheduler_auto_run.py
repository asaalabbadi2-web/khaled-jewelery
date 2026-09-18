"""test_bonus_scheduler_auto_run.py
=====================================
يثبت أن BonusScheduler.calculate_{daily,weekly,monthly}_bonuses() تنجح فعليًا
عند تشغيلها — لا Mock، لا استدعاء مباشر لـ _write_log بمكافأة وهمية.

هذا هو الفحص الذي غاب أربعة أشهر: من 2026-05-31 (commit 09f9e08) حتى
2026-09-18، كانت هذه الطرق الثلاث تتحطم دائمًا بـ

    AttributeError: type object 'BonusRule' has no attribute 'goal_period'

لأن الفلتر goal_period_filter الذي أضافه ذلك الـcommit أشار إلى عمود لم يوجد
قط على BonusRule (هو موجود على GoalAchievement، نموذج مختلف تمامًا). اختبارات
Phase 7 القائمة (test_bonus_phase7_auto_cycle.py) تفحص _write_log مباشرة بمكافأة
وهمية، فلم تستدعِ المسار الحقيقي إطلاقًا — وهذا بالضبط ما تسدّه هذه الاختبارات.
"""

from datetime import date, datetime

import pytest

from app import app
from bonus_scheduler import BonusScheduler
from models import BonusCalculationLog, BonusRule, Employee, EmployeeBonus, db


@pytest.fixture
def scheduler_employee_and_rule():
    """موظف وقاعدة مخصّصان لهذا الملف — لا اعتماد على بيانات بيئة أخرى."""
    with app.app_context():
        import uuid
        emp = Employee(
            employee_code=f'SCHED-TEST-{uuid.uuid4().hex[:8]}',
            name='موظف اختبار المجدول',
            job_title='مندوب مبيعات',
            is_active=True,
            salary=3000.0,
        )
        db.session.add(emp)
        db.session.flush()

        rule = BonusRule(
            name='scheduler_auto_run_test_rule',
            rule_type='fixed',
            bonus_type='fixed',
            bonus_value=250.0,
            is_active=True,
            created_by='test',
        )
        db.session.add(rule)
        db.session.commit()

        emp_id, rule_id = emp.id, rule.id
        yield emp_id, rule_id

        EmployeeBonus.query.filter_by(bonus_rule_id=rule_id).delete()
        BonusRule.query.filter_by(id=rule_id).delete()
        Employee.query.filter_by(id=emp_id).delete()
        BonusCalculationLog.query.filter(
            BonusCalculationLog.message.isnot(None),
            BonusCalculationLog.message.like('%goal_period%'),
        ).delete(synchronize_session=False)
        db.session.commit()


class TestSchedulerMethodsRunWithoutCrashing:
    """الثلاثة كانت تتحطم دائمًا؛ يجب أن تنجح الآن وتكتب سجل success."""

    def test_daily_scheduler_run_succeeds(self, scheduler_employee_and_rule):
        with app.app_context():
            before = BonusCalculationLog.query.count()

        scheduler = BonusScheduler(app)
        scheduler.calculate_daily_bonuses()  # لا استثناء ⇒ الاختبار ينجح

        with app.app_context():
            after = BonusCalculationLog.query.count()
            log = (
                BonusCalculationLog.query
                .filter_by(period_type='daily')
                .order_by(BonusCalculationLog.id.desc())
                .first()
            )
            assert after > before
            assert log is not None
            assert log.status == 'success', (
                f'توقّع نجاح التشغيل اليومي، وُجد: {log.status} — {log.message}'
            )
            assert log.message is None or 'goal_period' not in log.message

    def test_weekly_scheduler_run_succeeds(self, scheduler_employee_and_rule):
        with app.app_context():
            before = BonusCalculationLog.query.count()

        scheduler = BonusScheduler(app)
        scheduler.calculate_weekly_bonuses()

        with app.app_context():
            after = BonusCalculationLog.query.count()
            log = (
                BonusCalculationLog.query
                .filter_by(period_type='weekly')
                .order_by(BonusCalculationLog.id.desc())
                .first()
            )
            assert after > before
            assert log is not None
            assert log.status == 'success', (
                f'توقّع نجاح التشغيل الأسبوعي، وُجد: {log.status} — {log.message}'
            )

    def test_monthly_scheduler_run_succeeds(self, scheduler_employee_and_rule):
        with app.app_context():
            before = BonusCalculationLog.query.count()

        scheduler = BonusScheduler(app)
        scheduler.calculate_monthly_bonuses()

        with app.app_context():
            after = BonusCalculationLog.query.count()
            log = (
                BonusCalculationLog.query
                .filter_by(period_type='monthly')
                .order_by(BonusCalculationLog.id.desc())
                .first()
            )
            assert after > before
            assert log is not None
            assert log.status == 'success', (
                f'توقّع نجاح التشغيل الشهري، وُجد: {log.status} — {log.message}'
            )

    def test_daily_run_actually_creates_a_pending_bonus_for_the_fixed_rule(
        self, scheduler_employee_and_rule
    ):
        """لا يكفي "لم يتحطم" — يجب أن يُنتج فعليًا ما تنتجه قاعدة fixed دائمًا."""
        emp_id, rule_id = scheduler_employee_and_rule
        yesterday = date.today()
        from datetime import timedelta
        yesterday = date.today() - timedelta(days=1)

        scheduler = BonusScheduler(app)
        scheduler.calculate_daily_bonuses()

        with app.app_context():
            bonus = EmployeeBonus.query.filter_by(
                employee_id=emp_id, bonus_rule_id=rule_id,
                period_start=yesterday, period_end=yesterday,
            ).first()
            assert bonus is not None, 'قاعدة fixed يجب أن تُنتج مكافأة لكل تشغيل'
            assert bonus.status == 'pending'
            assert bonus.amount == 250.0


class TestNoPeriodConceptOnBonusRule:
    """يوثّق بالاختبار حقيقة معمارية: BonusRule لا يحمل مفهوم فترة.

    لو أُضيف مستقبلًا فلتر بحسب الفترة، فيجب أن يعتمد على عمود موجود فعلًا على
    BonusRule (لا على GoalAchievement أو Employee) — هذا الاختبار يمنع تكرار
    الخطأ نفسه: الإشارة إلى عمود غير موجود دون أن يفشل شيء حتى وقت التشغيل.
    """

    def test_goal_period_filter_parameter_no_longer_exists(self):
        import inspect
        from bonus_calculator import BonusCalculator

        sig = inspect.signature(BonusCalculator.calculate_all_bonuses_for_period)
        assert 'goal_period_filter' not in sig.parameters, (
            'goal_period_filter أُزيل لأنه أشار إلى عمود غير موجود على BonusRule؛ '
            'إعادته يجب أن تكون مصحوبة بعمود حقيقي، لا اسمًا مكررًا'
        )

    def test_bonus_rule_has_no_period_column(self):
        assert not hasattr(BonusRule, 'goal_period'), (
            'BonusRule اكتسب عمود goal_period — إن كان هذا مقصودًا فحدّث '
            'calculate_all_bonuses_for_period ليستخدمه، وحدّث هذا الاختبار'
        )
