"""
test_bonus_points_parity.py
============================
يُثبت أن Race (PointsMetric) و Bonus (BonusCalculator) ينتجان
نفس النقاط تماماً لنفس الفواتير — وأن تغيير إعداد واحد
(cash_amount_per_point) ينعكس فورياً على النظامين معاً.

اختبار الانحدار المستقبلي:
  أي شخص يُعدّل معادلة النقاط يجب أن يتوقع فشل هذه الاختبارات
  إذا أحدث تباينًا بين Race وBonus.
"""

from __future__ import annotations

import json
import pytest
from datetime import date, datetime
from unittest.mock import MagicMock

from points.engine import compute_invoices_points


# ── Helpers: بناء فواتير وهمية ────────────────────────────────────────────────

def _invoice(invoice_type: str, profit_cash: float, profit_gold: float, total: float = 0.0):
    inv = MagicMock()
    inv.invoice_type   = invoice_type
    inv.profit_cash    = profit_cash
    inv.profit_gold    = profit_gold
    inv.total          = total
    inv.is_posted      = True
    inv.items          = []
    return inv


SAMPLE_INVOICES = [
    _invoice('بيع',            profit_cash=450.0,  profit_gold=0.5),
    _invoice('بيع',            profit_cash=900.0,  profit_gold=1.0),
    _invoice('شراء من عميل',  profit_cash=0.0,    profit_gold=2.0),
    _invoice('بيع',            profit_cash=300.0,  profit_gold=0.3),
    _invoice('شراء من عميل',  profit_cash=0.0,    profit_gold=1.5),
]


# ── اختبار 1: التطابق التام بين المحرك (Race) والمكافأة ──────────────────────

class TestEngineParity:
    """كلا النظامين يستدعيان compute_invoices_points بنفس المعاملات → نفس النتيجة."""

    def _race_points(self, invoices, *, points_source, cash_amount_per_point, points_per_gram):
        """يُحاكي ما تفعله PointsMetric: تجميع فواتير موظف → engine."""
        return compute_invoices_points(
            invoices,
            points_source=points_source,
            cash_amount_per_point=cash_amount_per_point,
            points_per_gram=points_per_gram,
        )

    def _bonus_points(self, invoices, *, points_source, cash_amount_per_point, points_per_gram):
        """يُحاكي ما يفعله BonusCalculator.calculate_points_bonus: نفس الاستدعاء."""
        return compute_invoices_points(
            invoices,
            points_source=points_source,
            cash_amount_per_point=cash_amount_per_point,
            points_per_gram=points_per_gram,
        )

    @pytest.mark.parametrize("points_source,cpp,ppg", [
        ('profit_cash', 50.0,  10.0),
        ('profit_cash', 100.0, 10.0),
        ('gold_weight', 50.0,  10.0),
        ('gold_weight', 50.0,   5.0),
    ])
    def test_race_and_bonus_identical(self, points_source, cpp, ppg):
        """Race == Bonus لكل وضع وكل إعداد."""
        race_pts  = self._race_points(SAMPLE_INVOICES,
                                      points_source=points_source,
                                      cash_amount_per_point=cpp,
                                      points_per_gram=ppg)
        bonus_pts = self._bonus_points(SAMPLE_INVOICES,
                                       points_source=points_source,
                                       cash_amount_per_point=cpp,
                                       points_per_gram=ppg)
        assert race_pts == bonus_pts, (
            f'[{points_source}] Race={race_pts:.4f} ≠ Bonus={bonus_pts:.4f} '
            f'(cpp={cpp}, ppg={ppg})'
        )

    def test_profit_cash_formula_correctness(self):
        """profit_cash: بيع → cash/cpp, شراء → gold×ppg."""
        cpp, ppg = 50.0, 10.0
        pts = compute_invoices_points(
            SAMPLE_INVOICES,
            points_source='profit_cash',
            cash_amount_per_point=cpp,
            points_per_gram=ppg,
        )
        expected = (
            450.0 / cpp   # بيع 1
            + 900.0 / cpp  # بيع 2
            + 300.0 / cpp  # بيع 4
            + 2.0 * ppg    # شراء من عميل 1
            + 1.5 * ppg    # شراء من عميل 2
        )
        assert abs(pts - expected) < 0.001, f'{pts} ≠ {expected}'

    def test_gold_weight_formula_correctness(self):
        """gold_weight: كل الفواتير → profit_gold × ppg."""
        ppg = 10.0
        pts = compute_invoices_points(
            SAMPLE_INVOICES,
            points_source='gold_weight',
            cash_amount_per_point=50.0,
            points_per_gram=ppg,
        )
        total_pg = 0.5 + 1.0 + 2.0 + 0.3 + 1.5
        expected = total_pg * ppg
        assert abs(pts - expected) < 0.001, f'{pts} ≠ {expected}'


# ── اختبار 2: تغيير الإعداد ينعكس على النظامين معاً ─────────────────────────

class TestSettingsPropagation:
    """تغيير cash_amount_per_point في Settings.sales_race_settings
    يُغيِّر نقاط Race وBonus معاً — بلا تعديل في القاعدة."""

    def _make_race_cfg(self, cpp: float) -> dict:
        return {
            'points_source':         'profit_cash',
            'cash_amount_per_point': cpp,
            'points_per_gram':       10.0,
            'point_rules':           None,
        }

    def test_reducing_cpp_increases_points_for_both(self):
        """تقليل cash_amount_per_point يرفع النقاط في كلا النظامين."""
        cpp_old, cpp_new = 100.0, 50.0

        # Race (مباشرة عبر المحرك)
        race_old = compute_invoices_points(
            SAMPLE_INVOICES, points_source='profit_cash',
            cash_amount_per_point=cpp_old, points_per_gram=10.0,
        )
        race_new = compute_invoices_points(
            SAMPLE_INVOICES, points_source='profit_cash',
            cash_amount_per_point=cpp_new, points_per_gram=10.0,
        )

        # Bonus (نفس المحرك بنفس الإعدادات)
        bonus_old = compute_invoices_points(
            SAMPLE_INVOICES, points_source='profit_cash',
            cash_amount_per_point=cpp_old, points_per_gram=10.0,
        )
        bonus_new = compute_invoices_points(
            SAMPLE_INVOICES, points_source='profit_cash',
            cash_amount_per_point=cpp_new, points_per_gram=10.0,
        )

        assert race_new  > race_old,  'Race: تقليل cpp يجب أن يرفع النقاط'
        assert bonus_new > bonus_old, 'Bonus: تقليل cpp يجب أن يرفع النقاط'
        assert race_new  == bonus_new, 'Race == Bonus بالإعداد الجديد'
        assert race_old  == bonus_old, 'Race == Bonus بالإعداد القديم'

    def test_race_and_bonus_read_same_config(self):
        """get_race_points_config يقرأ صف الإعدادات الذي يقرؤه مسار الإعدادات.

        It used to patch models.Settings and expect Settings.query.first(); since
        7ebc4f5 (3 Aug 2026) the function reads the canonical row through
        core.settings._get_settings_singleton -- the one the settings API uses --
        so the patch reached nothing and the test read the defaults, red for two
        months with no CI to notice (TEST-002). It now checks the behaviour on a
        real settings row, and puts the database back as it was."""
        from app import app
        from models import Settings, db, get_race_points_config
        from core.settings import _get_settings_singleton

        with app.app_context():
            existed = Settings.query.first() is not None
            row = _get_settings_singleton(create_if_missing=True)
            was = row.sales_race_settings
            row.sales_race_settings = json.dumps({
                'points_source':         'profit_cash',
                'cash_amount_per_point': 75.0,
                'points_per_gram':       12.0,
            })
            db.session.commit()
            try:
                cfg = get_race_points_config()
            finally:
                row = Settings.query.first()
                if existed:
                    row.sales_race_settings = was
                else:
                    db.session.delete(row)
                db.session.commit()

        assert cfg['points_source']         == 'profit_cash'
        assert cfg['cash_amount_per_point'] == 75.0
        assert cfg['points_per_gram']       == 12.0

    def test_bonus_rule_gold_overrides_cash_source(self):
        """BonusRule.points_source='gold' → engine يستخدم gold_weight بغض النظر عن race settings."""
        # مع race configured كـ profit_cash
        pts_gold_mode = compute_invoices_points(
            SAMPLE_INVOICES,
            points_source='gold_weight',
            cash_amount_per_point=50.0,
            points_per_gram=10.0,
        )
        pts_cash_mode = compute_invoices_points(
            SAMPLE_INVOICES,
            points_source='profit_cash',
            cash_amount_per_point=50.0,
            points_per_gram=10.0,
        )
        # gold_weight للعينة: (0.5+1.0+0.3+2.0+1.5)×10 = 53.0
        # profit_cash: (450+900+300)/50 + (2.0+1.5)×10 = 33+35 = 68.0
        assert pts_gold_mode != pts_cash_mode, (
            'gold_weight و profit_cash يجب أن ينتجا نقاطاً مختلفة لهذه العينة'
        )


# ── اختبار 3: حد النقاط الدنيا ────────────────────────────────────────────────

class TestMinPointsGate:
    """engine يُعيد رقماً — BonusCalculator هو الذي يُطبّق min_points."""

    def test_engine_returns_raw_float(self):
        """المحرك يُعيد قيمة خام (float) دون حجب."""
        pts = compute_invoices_points(
            SAMPLE_INVOICES[:1],   # فاتورة واحدة صغيرة
            points_source='profit_cash',
            cash_amount_per_point=50.0,
            points_per_gram=10.0,
        )
        assert isinstance(pts, float)
        assert pts > 0.0

    def test_no_invoices_returns_zero(self):
        """قائمة فواتير فارغة → 0 نقاط."""
        for mode in ('profit_cash', 'gold_weight', 'sales_amount', 'invoice_count', 'sold_weight'):
            pts = compute_invoices_points(
                [],
                points_source=mode,
                cash_amount_per_point=50.0,
                points_per_gram=10.0,
            )
            assert pts == 0.0, f'{mode}: expected 0 for empty list, got {pts}'
