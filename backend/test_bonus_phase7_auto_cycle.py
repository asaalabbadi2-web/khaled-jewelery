"""
test_bonus_phase7_auto_cycle.py
================================
اختبارات Phase 7 — الاحتساب التلقائي الدوري.

معايير القبول:
  1. مكافأة approved لا تُعاد أبداً (immutable).
  2. مكافأة paid لا تُعاد أبداً (immutable).
  3. مكافأة pending تُعاد (يتحدث المبلغ).
  4. مكافأة rejected لا تُعاد (قرار إداري).
  5. auto_approve في جسم الطلب يُتجاهل — المكافأة تبقى pending.
  6. calculate_all_bonuses_for_period لا يقبل auto_approve كمعامل.
  7. GET /api/bonuses/pending-summary يُعيد الأعداد والإجماليات الصحيحة.
  8. الاحتساب اليدوي يكتب سجلاً في BonusCalculationLog.
  9. BonusCalculationLog يُسجَّل بعد Scheduler mock.
"""

import pytest
from datetime import date, datetime

from app import app
from models import db, Employee, BonusRule, EmployeeBonus, BonusCalculationLog, User
from bonus_calculator import BonusCalculator


# ── Helpers ───────────────────────────────────────────────────────────────────

PERIOD = (date(2026, 9, 1), date(2026, 9, 30))


def _make_rule():
    rule = BonusRule(
        name='phase7_test_rule',
        rule_type='fixed',
        bonus_type='fixed',
        bonus_value=400.0,
        is_active=True,
        created_by='test',
    )
    db.session.add(rule)
    db.session.flush()
    return rule


def _make_bonus(emp, rule, status='pending'):
    bonus = EmployeeBonus(
        employee_id=emp.id,
        bonus_rule_id=rule.id,
        bonus_type='fixed',
        amount=400.0,
        status=status,
        period_start=PERIOD[0],
        period_end=PERIOD[1],
        created_at=datetime.now(),
    )
    if status in ('approved', 'paid'):
        bonus.approved_by = 'test_admin'
        bonus.approved_at = datetime.now()
    db.session.add(bonus)
    db.session.flush()
    return bonus


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def auth_token():
    with app.app_context():
        from auth_decorators import generate_token
        admin = User.query.filter_by(username='admin').first()
        assert admin
        return f'Bearer {generate_token(admin)}'


@pytest.fixture
def emp_and_rule():
    with app.app_context():
        emp = Employee.query.filter_by(is_active=True).first()
        assert emp
        rule = _make_rule()
        db.session.commit()
        yield emp.id, rule.id
        # The bonuses before the rule they name: PostgreSQL enforces the key (TEST-001).
        EmployeeBonus.query.filter_by(bonus_rule_id=rule.id).delete()
        BonusRule.query.filter_by(id=rule.id).delete()
        db.session.commit()


# ── Immutability Tests ────────────────────────────────────────────────────────

class TestCalculationImmutability:

    def test_approved_bonus_is_not_recalculated(self, emp_and_rule):
        """مكافأة approved → تُعاد في النتيجة دون تعديل."""
        emp_id, rule_id = emp_and_rule
        with app.app_context():
            emp = Employee.query.get(emp_id)
            rule = BonusRule.query.get(rule_id)
            original = _make_bonus(emp, rule, status='approved')
            original.amount = 999.0  # مبلغ يختلف عن ما سيُحسب
            db.session.commit()
            original_id = original.id

            results = BonusCalculator.calculate_all_bonuses_for_period(
                *PERIOD, employee_ids=[emp_id], rule_ids=[rule_id],
            )

        with app.app_context():
            refreshed = EmployeeBonus.query.get(original_id)
            assert refreshed.status == 'approved', 'الحالة يجب أن تبقى approved'
            assert refreshed.amount == 999.0, 'المبلغ يجب ألا يتغير'
            returned_ids = [b.id for b in results]
            assert original_id in returned_ids, 'المكافأة الموجودة تُعاد في النتيجة'

    def test_paid_bonus_is_not_recalculated(self, emp_and_rule):
        """مكافأة paid → غير قابلة للمساس."""
        emp_id, rule_id = emp_and_rule
        with app.app_context():
            emp = Employee.query.get(emp_id)
            rule = BonusRule.query.get(rule_id)
            original = _make_bonus(emp, rule, status='paid')
            original.amount = 888.0
            db.session.commit()
            original_id = original.id

            BonusCalculator.calculate_all_bonuses_for_period(
                *PERIOD, employee_ids=[emp_id], rule_ids=[rule_id],
            )

        with app.app_context():
            refreshed = EmployeeBonus.query.get(original_id)
            assert refreshed.status == 'paid'
            assert refreshed.amount == 888.0

    def test_pending_bonus_is_recalculated(self, emp_and_rule):
        """مكافأة pending → يُعاد احتسابها ويتحدث المبلغ."""
        emp_id, rule_id = emp_and_rule
        with app.app_context():
            emp = Employee.query.get(emp_id)
            rule = BonusRule.query.get(rule_id)
            existing = _make_bonus(emp, rule, status='pending')
            existing.amount = 1.0   # مبلغ خاطئ قديم
            db.session.commit()
            existing_id = existing.id

            BonusCalculator.calculate_all_bonuses_for_period(
                *PERIOD, employee_ids=[emp_id], rule_ids=[rule_id],
            )

        with app.app_context():
            refreshed = EmployeeBonus.query.get(existing_id)
            assert refreshed.status == 'pending'
            assert refreshed.amount == 400.0, 'المبلغ يجب أن يُحدَّث إلى قيمة القاعدة'

    def test_rejected_bonus_is_not_recalculated(self, emp_and_rule):
        """مكافأة rejected → قرار إداري لا يُتجاوز."""
        emp_id, rule_id = emp_and_rule
        with app.app_context():
            emp = Employee.query.get(emp_id)
            rule = BonusRule.query.get(rule_id)
            existing = _make_bonus(emp, rule, status='rejected')
            existing.amount = 50.0
            db.session.commit()
            existing_id = existing.id

            BonusCalculator.calculate_all_bonuses_for_period(
                *PERIOD, employee_ids=[emp_id], rule_ids=[rule_id],
            )

        with app.app_context():
            refreshed = EmployeeBonus.query.get(existing_id)
            assert refreshed.status == 'rejected'
            assert refreshed.amount == 50.0

    def test_new_bonus_always_pending(self, emp_and_rule):
        """مكافأة جديدة → تُنشأ دائماً بحالة pending."""
        emp_id, rule_id = emp_and_rule
        with app.app_context():
            results = BonusCalculator.calculate_all_bonuses_for_period(
                *PERIOD, employee_ids=[emp_id], rule_ids=[rule_id],
            )

        assert results, 'يجب أن تُنشأ مكافأة'
        assert all(b.status == 'pending' for b in results), (
            'جميع المكافآت الجديدة يجب أن تكون pending'
        )

    def test_calculate_all_does_not_accept_auto_approve(self):
        """calculate_all_bonuses_for_period لا يقبل auto_approve كمعامل."""
        import inspect
        sig = inspect.signature(BonusCalculator.calculate_all_bonuses_for_period)
        assert 'auto_approve' not in sig.parameters, (
            'auto_approve يجب أن يكون محذوفاً من توقيع الدالة'
        )


# ── Route Tests ───────────────────────────────────────────────────────────────

class TestCalculateRouteAutoApproveIgnored:

    def test_auto_approve_in_body_is_ignored(self, auth_token, emp_and_rule):
        """
        POST /api/bonuses/calculate مع auto_approve=true في الجسم
        → المكافأة تبقى pending (الحقل يُتجاهل).
        """
        emp_id, rule_id = emp_and_rule
        with app.test_client() as client:
            resp = client.post(
                '/api/bonuses/calculate',
                json={
                    'period_start': '2026-09-01',
                    'period_end': '2026-09-30',
                    'employee_ids': [emp_id],
                    'rule_ids': [rule_id],
                    'auto_approve': True,  # يجب أن يُتجاهل
                },
                headers={'Authorization': auth_token},
            )

        assert resp.status_code == 200, f"توقعنا 200 — {resp.get_json()}"
        body = resp.get_json()
        for bonus_dict in body.get('bonuses', []):
            assert bonus_dict['status'] == 'pending', (
                f'auto_approve يجب أن يُتجاهل — المكافأة {bonus_dict["id"]} حالتها: {bonus_dict["status"]}'
            )

    def test_manual_calculate_writes_log(self, auth_token, emp_and_rule):
        """POST /api/bonuses/calculate يكتب سجلاً في BonusCalculationLog."""
        emp_id, rule_id = emp_and_rule

        with app.app_context():
            before = BonusCalculationLog.query.count()

        with app.test_client() as client:
            client.post(
                '/api/bonuses/calculate',
                json={
                    'period_start': '2026-09-01',
                    'period_end': '2026-09-30',
                    'employee_ids': [emp_id],
                    'rule_ids': [rule_id],
                },
                headers={'Authorization': auth_token},
            )

        with app.app_context():
            after = BonusCalculationLog.query.count()

        assert after > before, 'يجب أن يُكتب سجل تشغيل في BonusCalculationLog'

        with app.app_context():
            log = BonusCalculationLog.query.filter_by(period_type='manual').order_by(
                BonusCalculationLog.id.desc()
            ).first()
            assert log is not None
            assert log.status == 'success'
            assert log.period_start.isoformat() == '2026-09-01'


# ── Pending Summary Tests ─────────────────────────────────────────────────────

class TestPendingSummary:

    def test_pending_summary_default_period(self, auth_token):
        """GET /api/bonuses/pending-summary بدون params → 200 + الحقول موجودة."""
        with app.test_client() as client:
            resp = client.get(
                '/api/bonuses/pending-summary',
                headers={'Authorization': auth_token},
            )
        assert resp.status_code == 200
        body = resp.get_json()
        assert 'pending' in body
        assert 'approved' in body
        assert 'paid' in body
        assert 'period' in body
        assert 'count' in body['pending']
        assert 'total' in body['pending']

    def test_pending_summary_counts_correctly(self, auth_token, emp_and_rule):
        """
        pending-summary يعيد العدد الصحيح لفترة محددة.
        """
        emp_id, rule_id = emp_and_rule
        with app.app_context():
            emp = Employee.query.get(emp_id)
            rule = BonusRule.query.get(rule_id)
            b = _make_bonus(emp, rule, status='pending')
            b.amount = 500.0
            db.session.commit()
            bonus_id = b.id

        with app.test_client() as client:
            resp = client.get(
                '/api/bonuses/pending-summary?period_start=2026-09-01&period_end=2026-09-30',
                headers={'Authorization': auth_token},
            )

        with app.app_context():
            EmployeeBonus.query.filter_by(id=bonus_id).delete()
            db.session.commit()

        assert resp.status_code == 200
        body = resp.get_json()
        assert body['pending']['count'] >= 1
        assert body['pending']['total'] >= 500.0

    def test_calculation_logs_endpoint(self, auth_token):
        """GET /api/bonuses/calculation-logs → 200 + قائمة سجلات."""
        with app.test_client() as client:
            resp = client.get(
                '/api/bonuses/calculation-logs',
                headers={'Authorization': auth_token},
            )
        assert resp.status_code == 200
        body = resp.get_json()
        assert 'logs' in body
        assert isinstance(body['logs'], list)


# ── Scheduler Log Test ────────────────────────────────────────────────────────

class TestSchedulerLog:

    def test_scheduler_write_log_on_success(self):
        """_write_log يُنشئ BonusCalculationLog بعد تشغيل ناجح."""
        from bonus_scheduler import _write_log

        with app.app_context():
            before = BonusCalculationLog.query.count()

        # نُنشئ مكافأة وهمية لتمريرها إلى _write_log
        class _FakeBonus:
            status = 'pending'
            amount = 300.0

        _write_log(
            app,
            period_type='monthly',
            period_start=date(2026, 8, 1),
            period_end=date(2026, 8, 31),
            bonuses=[_FakeBonus()],
        )

        with app.app_context():
            after = BonusCalculationLog.query.count()
            log = BonusCalculationLog.query.filter_by(
                period_type='monthly',
                period_start=date(2026, 8, 1),
            ).order_by(BonusCalculationLog.id.desc()).first()

        assert after > before
        assert log is not None
        assert log.status == 'success'
        assert log.bonus_count == 1
        assert log.total_amount == 300.0

    def test_scheduler_write_log_on_failure(self):
        """_write_log يُسجَّل بحالة failed عند حدوث خطأ."""
        from bonus_scheduler import _write_log

        _write_log(
            app,
            period_type='daily',
            period_start=date(2026, 8, 15),
            period_end=date(2026, 8, 15),
            error=RuntimeError('اتصال قاعدة البيانات فشل'),
        )

        with app.app_context():
            log = BonusCalculationLog.query.filter_by(
                period_type='daily',
                period_start=date(2026, 8, 15),
                status='failed',
            ).order_by(BonusCalculationLog.id.desc()).first()

        assert log is not None
        assert 'اتصال' in (log.message or '')
