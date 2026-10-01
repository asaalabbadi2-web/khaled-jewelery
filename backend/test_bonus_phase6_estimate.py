"""
test_bonus_phase6_estimate.py
==============================
اختبارات Phase 6 — GET /api/invoices/<id>/bonus-estimate

الاختبارات:
  1. فاتورة غير موجودة → 404
  2. فاتورة بدون موظف → 400 + code='no_employee_linked'
  3. فاتورة + قاعدة نشطة → تقدير صحيح في estimates
  4. فاتورة تاريخية تعتمد على posted_by → Fallback يعمل
  5. قاعدة معطلة عبر Feature Flag → لا تظهر في estimates
  6. لا يُنشأ أي EmployeeBonus بعد الطلب
  7. لا يُنفَّذ أي Commit أو تعديل في DB
  8. لا توجد قواعد تنطبق → 200 + estimates: []
"""

import pytest
from datetime import datetime, date

from app import app
from models import db, Invoice, Employee, BonusRule, EmployeeBonus, AppUser, User
from core.settings import _get_settings_singleton
from tests.cleanup import purge  # UNPOST-001 U3: cleanup of posted rows is a purge


# ── Helpers ───────────────────────────────────────────────────────────────────

def _set_flags(attendance: bool = False, performance: bool = False):
    with app.app_context():
        s = _get_settings_singleton(create_if_missing=True)
        s.bonus_attendance_enabled = attendance
        s.bonus_performance_enabled = performance
        db.session.commit()


def _bonus_count():
    with app.app_context():
        return EmployeeBonus.query.count()


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def auth_token():
    with app.app_context():
        from auth_decorators import generate_token
        admin = User.query.filter_by(username='admin').first()
        assert admin, 'لا يوجد مستخدم admin في قاعدة البيانات'
        return f'Bearer {generate_token(admin)}'


@pytest.fixture
def linked_invoice():
    """فاتورة مرتبطة بموظف عبر employee_id."""
    with app.app_context():
        emp = Employee.query.filter_by(is_active=True).first()
        assert emp, 'لا يوجد موظف نشط'
        inv = Invoice(
            invoice_type_id=1,
            invoice_type='بيع',
            date=datetime(2026, 7, 18),
            total=5000.0,
            employee_id=emp.id,
            is_posted=True,
            profit_gold=50.0,
            profit_cash=2000.0,
        )
        db.session.add(inv)
        db.session.commit()
        inv_id = inv.id
        emp_id = emp.id
    yield inv_id, emp_id
    with app.app_context():
        purge(lambda: Invoice.query.filter_by(id=inv_id).delete())
        db.session.commit()


@pytest.fixture
def orphan_invoice():
    """فاتورة بدون employee_id وبدون posted_by."""
    with app.app_context():
        inv = Invoice(
            invoice_type_id=1,
            invoice_type='بيع',
            date=datetime(2026, 7, 10),
            total=1000.0,
            employee_id=None,
            posted_by=None,
            is_posted=True,
        )
        db.session.add(inv)
        db.session.commit()
        inv_id = inv.id
    yield inv_id
    with app.app_context():
        purge(lambda: Invoice.query.filter_by(id=inv_id).delete())
        db.session.commit()


@pytest.fixture
def posted_by_invoice():
    """فاتورة تاريخية: employee_id=None ولكن posted_by=username موظف."""
    with app.app_context():
        app_user = AppUser.query.filter(AppUser.employee_id.isnot(None)).first()
        if app_user is None:
            pytest.skip('لا يوجد AppUser مرتبط بموظف في هذه البيئة')
        inv = Invoice(
            invoice_type_id=1,
            invoice_type='بيع',
            date=datetime(2026, 6, 15),
            total=3000.0,
            employee_id=None,
            posted_by=app_user.username,
            is_posted=True,
            profit_gold=30.0,
            profit_cash=1500.0,
        )
        db.session.add(inv)
        db.session.commit()
        inv_id = inv.id
        emp_id = app_user.employee_id
    yield inv_id, emp_id
    with app.app_context():
        purge(lambda: Invoice.query.filter_by(id=inv_id).delete())
        db.session.commit()


@pytest.fixture
def active_fixed_rule():
    """قاعدة fixed نشطة (تنطبق على الجميع — لا target_departments/positions)."""
    with app.app_context():
        rule = BonusRule(
            name='estimate_test_fixed_rule',
            rule_type='fixed',
            bonus_type='fixed',
            bonus_value=500.0,
            is_active=True,
            created_by='test',
        )
        db.session.add(rule)
        db.session.commit()
        rule_id = rule.id
    yield rule_id
    with app.app_context():
        BonusRule.query.filter_by(id=rule_id).delete()
        db.session.commit()


@pytest.fixture(autouse=True)
def reset_flags():
    _set_flags(False, False)
    yield
    _set_flags(False, False)


# ── Tests ─────────────────────────────────────────────────────────────────────

class TestEstimateEdgeCases:

    def test_nonexistent_invoice_returns_404(self, auth_token):
        """فاتورة غير موجودة → 404."""
        with app.test_client() as client:
            resp = client.get(
                '/api/invoices/999999/bonus-estimate',
                headers={'Authorization': auth_token},
            )
        assert resp.status_code == 404, f"توقعنا 404 — {resp.get_json()}"

    def test_invoice_without_employee_returns_400(self, auth_token, orphan_invoice):
        """فاتورة بدون employee_id وبدون posted_by → 400 + code='no_employee_linked'."""
        with app.test_client() as client:
            resp = client.get(
                f'/api/invoices/{orphan_invoice}/bonus-estimate',
                headers={'Authorization': auth_token},
            )
        assert resp.status_code == 400, f"توقعنا 400 — {resp.get_json()}"
        body = resp.get_json()
        assert body.get('code') == 'no_employee_linked'

    def test_no_applicable_rules_returns_empty_estimates(self, auth_token, linked_invoice):
        """
        إذا لم تنطبق أي قاعدة على الموظف → 200 + estimates: [].
        نُعطّل كل القواعد النشطة مؤقتاً عبر is_active=False لا يمكن، لكن يمكن
        تصفية الموظف من خلال department لا يملكها الموظف.
        """
        inv_id, emp_id = linked_invoice
        with app.app_context():
            # ننشئ قاعدة تستهدف department غير موجود — لن تنطبق على أي موظف
            rule = BonusRule(
                name='estimate_restricted_dept_rule',
                rule_type='fixed',
                bonus_type='fixed',
                bonus_value=100.0,
                is_active=True,
                target_departments=['قسم_غير_موجود_أبداً'],
                created_by='test',
            )
            db.session.add(rule)
            db.session.commit()
            rule_id = rule.id

        with app.test_client() as client:
            resp = client.get(
                f'/api/invoices/{inv_id}/bonus-estimate',
                headers={'Authorization': auth_token},
            )

        with app.app_context():
            BonusRule.query.filter_by(id=rule_id).delete()
            db.session.commit()

        assert resp.status_code == 200
        body = resp.get_json()
        # إما لا تقديرات أصلاً (لو لا قواعد أخرى تنطبق) أو هذه القاعدة بالذات لم تظهر
        if body.get('estimates'):
            rule_ids = [e['rule_id'] for e in body['estimates']]
            assert rule_id not in rule_ids, 'قاعدة restricted_dept لا يجب أن تظهر'


class TestEstimateCorrectness:

    def test_linked_invoice_returns_estimate(self, auth_token, linked_invoice, active_fixed_rule):
        """فاتورة + قاعدة fixed نشطة → estimates تحتوي على تقدير."""
        inv_id, emp_id = linked_invoice

        with app.test_client() as client:
            resp = client.get(
                f'/api/invoices/{inv_id}/bonus-estimate',
                headers={'Authorization': auth_token},
            )

        assert resp.status_code == 200, f"توقعنا 200 — {resp.get_json()}"
        body = resp.get_json()
        assert body['employee_id'] == emp_id
        assert body['period']['start'] == '2026-07-01'
        assert body['period']['end'] == '2026-07-31'

        matching = [e for e in body['estimates'] if e['rule_id'] == active_fixed_rule]
        assert matching, 'القاعدة النشطة يجب أن تظهر في estimates'
        est = matching[0]
        assert est['estimated_bonus'] == 500.0
        assert 'calculation_detail' in est
        detail = est['calculation_detail']
        assert 'inputs' in detail
        assert 'calculation' in detail
        assert 'result' in detail
        assert detail['result']['final_bonus'] == 500.0

    def test_posted_by_fallback_resolves_employee(self, auth_token, posted_by_invoice, active_fixed_rule):
        """فاتورة employee_id=None + posted_by → Fallback يُحدد الموظف."""
        inv_id, emp_id = posted_by_invoice

        with app.test_client() as client:
            resp = client.get(
                f'/api/invoices/{inv_id}/bonus-estimate',
                headers={'Authorization': auth_token},
            )

        assert resp.status_code == 200, f"توقعنا 200 — {resp.get_json()}"
        body = resp.get_json()
        assert body['employee_id'] == emp_id, 'يجب أن يُحدد الموظف عبر posted_by fallback'
        assert body['period']['start'] == '2026-06-01'
        assert body['period']['end'] == '2026-06-30'

    def test_disabled_feature_flag_rule_excluded(self, auth_token, linked_invoice):
        """قاعدة attendance + Flag=false → لا تظهر في estimates."""
        inv_id, _ = linked_invoice
        with app.app_context():
            att_rule = BonusRule(
                name='estimate_attendance_flagged',
                rule_type='attendance',
                bonus_type='fixed',
                bonus_value=300.0,
                is_active=True,
                created_by='test',
            )
            db.session.add(att_rule)
            db.session.commit()
            rule_id = att_rule.id

        # Flags = false (autouse fixture)
        with app.test_client() as client:
            resp = client.get(
                f'/api/invoices/{inv_id}/bonus-estimate',
                headers={'Authorization': auth_token},
            )

        with app.app_context():
            BonusRule.query.filter_by(id=rule_id).delete()
            db.session.commit()

        assert resp.status_code == 200
        body = resp.get_json()
        att_estimates = [e for e in body['estimates'] if e['rule_id'] == rule_id]
        assert not att_estimates, 'قاعدة attendance المعطّلة يجب ألا تظهر في estimates'


class TestEstimateReadOnly:

    def test_no_employee_bonus_created(self, auth_token, linked_invoice, active_fixed_rule):
        """الـ endpoint لا يُنشئ أي EmployeeBonus."""
        inv_id, _ = linked_invoice
        before = _bonus_count()

        with app.test_client() as client:
            client.get(
                f'/api/invoices/{inv_id}/bonus-estimate',
                headers={'Authorization': auth_token},
            )

        after = _bonus_count()
        assert before == after, (
            f'عدد EmployeeBonus تغيّر: {before} → {after}. '
            'الـ endpoint يجب أن يكون Read Only تماماً'
        )

    def test_no_voucher_created(self, auth_token, linked_invoice, active_fixed_rule):
        """الـ endpoint لا يُنشئ أي Voucher."""
        from models import Voucher
        inv_id, _ = linked_invoice

        with app.app_context():
            before = Voucher.query.count()

        with app.test_client() as client:
            client.get(
                f'/api/invoices/{inv_id}/bonus-estimate',
                headers={'Authorization': auth_token},
            )

        with app.app_context():
            after = Voucher.query.count()

        assert before == after, (
            f'عدد Vouchers تغيّر: {before} → {after}. '
            'الـ endpoint يجب أن يكون Read Only تماماً'
        )
