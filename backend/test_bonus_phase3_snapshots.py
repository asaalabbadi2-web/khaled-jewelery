"""
test_bonus_phase3_snapshots.py
================================
اختبارات Phase 3 — Rule Versioning (Snapshots).

الاختباران:
  1. snapshot_correctness:
       BonusCalculator.calculate_bonus() يُنتج:
       - rule_snapshot  يطابق rule.to_snapshot()
       - calculation_snapshot له مفاتيح {inputs, calculation, result}
       - calculation_snapshot.calculation.formula غير فارغة
       - calculation_snapshot.result.final_bonus == amount

  2. snapshot_immutability:
       - احسب مكافأة أولى (bonus_1) باستخدام rule_v1 (bonus_value=500)
       - عدّل القاعدة (bonus_value=999)
       - احسب مكافأة ثانية (bonus_2) عبر calculate_all_bonuses_for_period
         (فترة مختلفة → مكافأة جديدة)
       - تحقق: bonus_1.rule_snapshot['bonus_value'] == 500 (القيمة القديمة)
       - تحقق: bonus_2.rule_snapshot['bonus_value'] == 999 (القيمة الجديدة)
       - (إعادة حساب مكافأة معلّقة تحمل لقطة ما حسبها: tests/test_bonus_money_safety.py)
"""

import pytest
from datetime import date, datetime

from app import app
from models import db, Account, Employee, BonusRule, EmployeeBonus
from bonus_calculator import BonusCalculator


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope='module')
def phase3_accounts():
    """يضمن وجود حسابَي 5401 و 2310 المطلوبَين للاعتماد."""
    with app.app_context():
        for num, name, acct_type in [
            ('5401', 'مصروف مكافآت الموظفين', 'Expense'),
            ('2310', 'مكافآت مستحقة للموظفين', 'Liability'),
        ]:
            if not Account.query.filter_by(account_number=num).first():
                db.session.add(Account(
                    account_number=num, name=name,
                    type=acct_type, tracks_weight=False,
                ))
        db.session.commit()
    yield


@pytest.fixture
def fixed_rule(phase3_accounts):
    """ينشئ قاعدة fixed/fixed بقيمة 500 ويُعيد id-ها."""
    with app.app_context():
        rule = BonusRule(
            name='اختبار Phase3',
            rule_type='fixed',
            bonus_type='fixed',
            bonus_value=500.0,
            min_bonus=0.0,
            max_bonus=None,
            is_active=True,
            created_by='test',
        )
        db.session.add(rule)
        db.session.commit()
        return rule.id


# ── Tests ─────────────────────────────────────────────────────────────────────

class TestSnapshotCorrectness:
    """التحقق من بنية الـ Snapshot المُنتج."""

    def test_rule_snapshot_matches_to_snapshot(self, fixed_rule):
        """rule_snapshot يطابق rule.to_snapshot() لحظة الحساب."""
        with app.app_context():
            rule = BonusRule.query.get(fixed_rule)
            emp = Employee.query.first()
            assert emp, "يجب أن يكون هناك موظف مُهيَّأ في conftest"

            bonus = BonusCalculator.calculate_bonus(
                emp, rule,
                date(2026, 8, 1), date(2026, 8, 31),
            )
            assert bonus is not None, f"لم تُحسب أي مكافأة — rule: {rule.rule_type}/{rule.bonus_type}"

            expected = rule.to_snapshot()
            assert bonus.rule_snapshot == expected, (
                f"rule_snapshot لا يطابق to_snapshot():\n"
                f"  expected: {expected}\n"
                f"  got: {bonus.rule_snapshot}"
            )

    def test_calculation_snapshot_structure(self, fixed_rule):
        """calculation_snapshot يحتوي المقاطع الثلاثة ويكون مكتفياً ذاتياً."""
        with app.app_context():
            rule = BonusRule.query.get(fixed_rule)
            emp = Employee.query.first()

            bonus = BonusCalculator.calculate_bonus(
                emp, rule,
                date(2026, 8, 1), date(2026, 8, 31),
            )
            assert bonus is not None

            snap = bonus.calculation_snapshot
            assert snap is not None, "calculation_snapshot يجب أن يكون غير فارغ"

            # المقاطع الثلاثة
            for section in ('inputs', 'calculation', 'result'):
                assert section in snap, f"المقطع '{section}' مفقود من calculation_snapshot"

            calc = snap['calculation']
            assert calc.get('rule_type') == rule.rule_type
            assert calc.get('formula'), "formula يجب أن تكون غير فارغة"
            assert 'raw_amount' in calc
            assert 'min_bonus_applied' in calc
            assert 'max_bonus_applied' in calc

            result = snap['result']
            assert result.get('final_bonus') == round(bonus.amount, 4), (
                f"final_bonus={result.get('final_bonus')} لا يطابق amount={bonus.amount}"
            )

    def test_to_snapshot_independent_from_to_dict(self, fixed_rule):
        """to_snapshot() مستقل عن to_dict() — لا يتأثر بتغييرات الـ API."""
        with app.app_context():
            rule = BonusRule.query.get(fixed_rule)
            snap = rule.to_snapshot()
            full = rule.to_dict()

            # كلاهما يشتركان في الحقول الجوهرية
            for key in ('id', 'name', 'rule_type', 'bonus_type', 'bonus_value'):
                assert snap[key] == full[key], f"تعارض في '{key}': snap={snap[key]} / dict={full[key]}"

            # to_dict قد يحتوي حقولاً ليست في to_snapshot (مثل description)
            # هذا مقصود — to_snapshot لا يرث شكل to_dict بشكل ضمني


class TestSnapshotImmutability:
    """التحقق من أن الـ Snapshots write-once ولا تتغير عند إعادة الحساب."""

    def test_first_bonus_keeps_old_snapshot_after_rule_change(self, phase3_accounts):
        """
        1. أنشئ قاعدة بـ bonus_value=500
        2. احسب مكافأة للفترة أغسطس 2026 → bonus_1 يحفظ snapshot بـ bonus_value=500
        3. عدّل القاعدة إلى bonus_value=999
        4. احسب مكافأة للفترة سبتمبر 2026 → bonus_2 يحفظ snapshot بـ bonus_value=999
        """
        with app.app_context():
            emp = Employee.query.first()

            # ── 1. قاعدة v1 ──────────────────────────────────────────────
            rule = BonusRule(
                name='immutability_test',
                rule_type='fixed',
                bonus_type='fixed',
                bonus_value=500.0,
                min_bonus=0.0,
                max_bonus=None,
                is_active=True,
                created_by='test',
            )
            db.session.add(rule)
            db.session.commit()
            rule_id = rule.id

            # ── 2. حساب الفترة الأولى ────────────────────────────────────
            BonusCalculator.calculate_all_bonuses_for_period(
                date(2026, 8, 1), date(2026, 8, 31),
                employee_ids=[emp.id],
                rule_ids=[rule_id],
            )

            bonus_1 = EmployeeBonus.query.filter_by(
                employee_id=emp.id,
                bonus_rule_id=rule_id,
                period_start=date(2026, 8, 1),
            ).first()
            assert bonus_1 is not None, "لم تُنشأ المكافأة الأولى"
            assert bonus_1.rule_snapshot is not None, "rule_snapshot يجب أن يُملأ لحظة الإنشاء"
            assert bonus_1.rule_snapshot['bonus_value'] == 500.0, (
                f"snapshot_v1.bonus_value={bonus_1.rule_snapshot['bonus_value']} ≠ 500"
            )

            # ── 3. تعديل القاعدة ─────────────────────────────────────────
            rule.bonus_value = 999.0
            rule.name = 'immutability_test_v2'
            db.session.commit()

            # ── 4. حساب فترة مختلفة (سبتمبر) → مكافأة جديدة ────────────
            BonusCalculator.calculate_all_bonuses_for_period(
                date(2026, 9, 1), date(2026, 9, 30),
                employee_ids=[emp.id],
                rule_ids=[rule_id],
            )

            bonus_2 = EmployeeBonus.query.filter_by(
                employee_id=emp.id,
                bonus_rule_id=rule_id,
                period_start=date(2026, 9, 1),
            ).first()
            assert bonus_2 is not None, "لم تُنشأ المكافأة الثانية"
            assert bonus_2.rule_snapshot['bonus_value'] == 999.0, (
                f"snapshot_v2.bonus_value={bonus_2.rule_snapshot['bonus_value']} ≠ 999"
            )

            # A pending bonus recomputed carries the snapshot of what computed
            # it, with its amount (bonus study م0, ث7): it was pinned here to
            # keep its first snapshot while its amount followed the rule. The
            # law and its witness: tests/test_bonus_money_safety.py.
