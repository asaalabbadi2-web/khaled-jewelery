"""Integration tests for Phase 2B: PointsMetric with per-item (category, karat) scoring.

Design contract:
    bucket_profit = Σ(item.profit_weight × item.karat / main_karat)
    points        = bucket_profit × PointCalculator.calculate(category_id, karat, rules)

Zero Diff guarantee (proven mathematically):
    With DEFAULT_MULTIPLIER=10 and no custom rules:
        new_points  = Σ(profit_weight × karat/main_karat) × 10
                    = invoice.profit_gold × 10
                    = old_points
    This holds for ANY karat mix — not just same-karat items.

TDD split:
    - TestZeroDiff       → should PASS now (profit_gold already set correctly on Invoice)
    - TestWithRules      → should FAIL until Phase 2B implementation (rules not yet read)
    - TestRegression     → should PASS now, stays green after Phase 2B
"""
import itertools
import json
import uuid
from datetime import datetime

_invoice_type_id_counter = itertools.count(90_000)

import pytest

from app import app as flask_app
from models import db, Invoice, InvoiceItem, Employee, Category, Settings
from points.models import PointRule
from points.defaults import DEFAULT_MULTIPLIER


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    """Behind the fence (moved under tests/ 20 Oct 2026): its commits stayed in
    the run's database and the next file's «today» held them."""
    yield


MAIN_KARAT = 21.0


# ─── helpers ────────────────────────────────────────────────────────────────

def _unique(prefix: str) -> str:
    return f'{prefix}-{uuid.uuid4().hex[:8]}'


def _employee(code_prefix: str = 'EMP-INTG') -> Employee:
    emp = Employee(
        employee_code=_unique(code_prefix),
        name=_unique('موظف'),
        salary=0.0,
        is_active=True,
    )
    db.session.add(emp)
    db.session.flush()
    return emp


def _category(name_prefix: str) -> Category:
    cat = Category(name=_unique(name_prefix))
    db.session.add(cat)
    db.session.flush()
    return cat


def _invoice_with_items(
    employee_id: int,
    items: list[dict],
    *,
    invoice_type: str = 'بيع',
) -> Invoice:
    """Create a posted Invoice whose profit_gold equals Σ(item.profit_weight × karat / MAIN_KARAT).

    This construction guarantees the Zero Diff invariant by definition:
        new_points (no rules) = Σ(item.profit_weight × karat/main_karat) × 10
                              = profit_gold × 10
                              = old_points
    """
    profit_gold = sum(
        it['profit_weight'] * it['karat'] / MAIN_KARAT
        for it in items
    )
    inv = Invoice(
        invoice_type_id=next(_invoice_type_id_counter),
        invoice_type=invoice_type,
        employee_id=employee_id,
        date=datetime.now(),
        total=0.0,
        is_posted=True,
        profit_gold=round(profit_gold, 3),
    )
    db.session.add(inv)
    db.session.flush()

    for it in items:
        db.session.add(InvoiceItem(
            invoice_id=inv.id,
            category_id=it.get('category_id'),
            karat=float(it['karat']),
            profit_weight=float(it['profit_weight']),
            name=it.get('name', 'test-item'),
            quantity=1,
            price=0.0,
        ))

    db.session.commit()
    return inv


def _set_point_rules(rules: list[PointRule]) -> None:
    """Persist point_rules into sales_race_settings (Text/JSON) for the next request."""
    settings = Settings.query.first()
    if settings is None:
        settings = Settings()
        db.session.add(settings)
        db.session.flush()
    raw = settings.sales_race_settings
    cfg = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
    cfg['point_rules'] = [
        {
            'category_id': r.category_id,
            'karat': r.karat,
            'multiplier': r.multiplier,
        }
        for r in rules
    ]
    settings.sales_race_settings = json.dumps(cfg, ensure_ascii=False)
    db.session.commit()


def _clear_point_rules() -> None:
    settings = Settings.query.first()
    if settings is None:
        return
    raw = settings.sales_race_settings
    cfg = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
    cfg.pop('point_rules', None)
    settings.sales_race_settings = json.dumps(cfg, ensure_ascii=False)
    db.session.commit()


def _set_points_source(source: str, cash_amount_per_point=None) -> None:
    settings = Settings.query.first()
    if settings is None:
        settings = Settings()
        db.session.add(settings)
        db.session.flush()
    raw = settings.sales_race_settings
    cfg = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
    cfg['points_source'] = source
    if cash_amount_per_point is not None:
        cfg['cash_amount_per_point'] = cash_amount_per_point
    settings.sales_race_settings = json.dumps(cfg, ensure_ascii=False)
    db.session.commit()


def _reset_points_source() -> None:
    settings = Settings.query.first()
    if settings is None:
        return
    raw = settings.sales_race_settings
    cfg = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
    cfg.pop('points_source', None)
    cfg.pop('cash_amount_per_point', None)
    settings.sales_race_settings = json.dumps(cfg, ensure_ascii=False)
    db.session.commit()


def _invoice_cash(employee_id: int, *, profit_cash: float, invoice_type: str = 'بيع') -> Invoice:
    inv = Invoice(
        invoice_type_id=next(_invoice_type_id_counter),
        invoice_type=invoice_type,
        employee_id=employee_id,
        date=datetime.now(),
        total=0.0,
        is_posted=True,
        profit_gold=0.0,
        profit_cash=round(profit_cash, 2),
    )
    db.session.add(inv)
    db.session.commit()
    return inv


def _invoice_total(employee_id: int, *, total: float, invoice_type: str = 'بيع') -> Invoice:
    """Invoice with a known total (for sales_amount tests)."""
    inv = Invoice(
        invoice_type_id=next(_invoice_type_id_counter),
        invoice_type=invoice_type,
        employee_id=employee_id,
        date=datetime.now(),
        total=round(total, 2),
        is_posted=True,
        profit_gold=0.0,
    )
    db.session.add(inv)
    db.session.commit()
    return inv


def _invoice_with_weight(employee_id: int, *, weight_g: float, karat: float = 21.0,
                         invoice_type: str = 'بيع') -> Invoice:
    """Invoice with a physical item weight (for sold_weight tests)."""
    inv = Invoice(
        invoice_type_id=next(_invoice_type_id_counter),
        invoice_type=invoice_type,
        employee_id=employee_id,
        date=datetime.now(),
        total=0.0,
        is_posted=True,
        profit_gold=0.0,
    )
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceItem(
        invoice_id=inv.id,
        karat=float(karat),
        weight=float(weight_g),
        profit_weight=0.0,
        name='test-item',
        quantity=1,
        price=0.0,
    ))
    db.session.commit()
    return inv


def _leaderboard(auth_headers: dict) -> dict:
    with flask_app.test_client() as client:
        resp = client.get(
            '/api/home/leaderboard',
            query_string={'period': 'today', 'metric': 'points'},
            headers=auth_headers,
        )
    assert resp.status_code == 200
    return resp.get_json()


def _score_for(payload: dict, emp_id: int) -> float:
    ranking = payload.get('ranking') or []
    row = next((r for r in ranking if r.get('id') == emp_id), None)
    return float(row['score']) if row else 0.0


def _normalized_profit(items: list[dict]) -> float:
    return sum(it['profit_weight'] * it['karat'] / MAIN_KARAT for it in items)


# ─── Zero Diff tests ─────────────────────────────────────────────────────────

class TestZeroDiff:
    """No custom rules → points must equal invoice.profit_gold × DEFAULT_MULTIPLIER.

    These tests should PASS with both the current and Phase 2B PointsMetric,
    because profit_gold is set by construction to equal Σ(profit_weight × karat/main_karat).
    """

    def test_single_karat_single_employee(self, auth_headers):
        with flask_app.app_context():
            emp = _employee('EMP-ZD-1')
            items = [{'karat': 21.0, 'profit_weight': 5.0}]
            _invoice_with_items(emp.id, items)
            emp_id = emp.id
            expected = round(_normalized_profit(items) * DEFAULT_MULTIPLIER)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == expected

    def test_mixed_karats_single_employee(self, auth_headers):
        """21k + 18k items: new system = old system = profit_gold × 10."""
        with flask_app.app_context():
            emp = _employee('EMP-ZD-2')
            items = [
                {'karat': 21.0, 'profit_weight': 5.0},
                {'karat': 18.0, 'profit_weight': 2.0},
            ]
            inv = _invoice_with_items(emp.id, items)
            emp_id = emp.id
            # profit_gold was set to Σ(pw × k/mk) by construction
            expected = round(inv.profit_gold * DEFAULT_MULTIPLIER)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == expected

    def test_high_karat_single_employee(self, auth_headers):
        """24k item (above main karat): profit_gold contribution > profit_weight."""
        with flask_app.app_context():
            emp = _employee('EMP-ZD-3')
            items = [{'karat': 24.0, 'profit_weight': 4.0}]
            inv = _invoice_with_items(emp.id, items)
            emp_id = emp.id
            expected = round(inv.profit_gold * DEFAULT_MULTIPLIER)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == expected

    def test_multi_employee_multi_karat(self, auth_headers):
        """Each employee's score = their invoice.profit_gold × 10."""
        with flask_app.app_context():
            emp_a = _employee('EMP-ZD-A')
            emp_b = _employee('EMP-ZD-B')
            items_a = [
                {'karat': 21.0, 'profit_weight': 10.0},
                {'karat': 18.0, 'profit_weight': 3.0},
            ]
            items_b = [
                {'karat': 24.0, 'profit_weight': 4.0},
                {'karat': 21.0, 'profit_weight': 6.0},
            ]
            inv_a = _invoice_with_items(emp_a.id, items_a)
            inv_b = _invoice_with_items(emp_b.id, items_b)
            aid, bid = emp_a.id, emp_b.id
            exp_a = round(inv_a.profit_gold * DEFAULT_MULTIPLIER)
            exp_b = round(inv_b.profit_gold * DEFAULT_MULTIPLIER)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, aid) == exp_a
        assert _score_for(payload, bid) == exp_b

    def test_zero_diff_explicit_formula_verification(self, auth_headers):
        """Assert new_points == invoice.profit_gold × DEFAULT_MULTIPLIER directly."""
        with flask_app.app_context():
            emp = _employee('EMP-ZD-VRF')
            items = [
                {'karat': 21.0, 'profit_weight': 7.0},
                {'karat': 18.0, 'profit_weight': 3.0},
                {'karat': 24.0, 'profit_weight': 2.0},
            ]
            inv = _invoice_with_items(emp.id, items)
            emp_id = emp.id
            # Explicitly verify construction: profit_gold == Σ(pw × k/mk)
            computed = sum(it['profit_weight'] * it['karat'] / MAIN_KARAT for it in items)
            assert abs(inv.profit_gold - round(computed, 3)) < 0.001
            expected = round(inv.profit_gold * DEFAULT_MULTIPLIER)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == expected


# ─── Rules behavior tests ─────────────────────────────────────────────────────

class TestWithRules:
    """Per-(category, karat) multipliers override DEFAULT_MULTIPLIER.

    These tests should FAIL until Phase 2B is implemented (routes.py reads
    point_rules from settings and passes them to PointsMetric).

    Points formula with rules:
        points = Σ_buckets(bucket_profit × multiplier(category_id, karat))
        where bucket_profit = Σ_items_in_bucket(profit_weight × karat / main_karat)
    """

    def test_karat_specific_rules_gold(self, auth_headers):
        """Gold 21k → 10, Gold 18k → 8: same category, different karats."""
        with flask_app.app_context():
            emp = _employee('EMP-RUL-1')
            cat = _category('Gold')
            items = [
                {'karat': 21.0, 'category_id': cat.id, 'profit_weight': 5.0},
                {'karat': 18.0, 'category_id': cat.id, 'profit_weight': 2.0},
            ]
            _invoice_with_items(emp.id, items)
            emp_id, cat_id = emp.id, cat.id
            # Manual calculation:
            # bucket 21k: 5×21/21 × 10 = 50.0
            # bucket 18k: 2×18/21 × 8  ≈ 1.7143 × 8 ≈ 13.714
            # total ≈ 63.714 → round = 64
            bucket_21 = 5.0 * 21.0 / MAIN_KARAT * 10.0
            bucket_18 = 2.0 * 18.0 / MAIN_KARAT * 8.0
            expected = round(bucket_21 + bucket_18)
            _set_point_rules([
                PointRule(category_id=cat_id, karat=21.0, multiplier=10.0),
                PointRule(category_id=cat_id, karat=18.0, multiplier=8.0),
            ])

        payload = _leaderboard(auth_headers)
        with flask_app.app_context():
            _clear_point_rules()
        assert _score_for(payload, emp_id) == expected

    def test_category_only_rule_bullion(self, auth_headers):
        """Bullion (any karat) → 2 multiplier."""
        with flask_app.app_context():
            emp = _employee('EMP-RUL-2')
            cat = _category('Bullion')
            items = [
                {'karat': 24.0, 'category_id': cat.id, 'profit_weight': 4.0},
                {'karat': 21.0, 'category_id': cat.id, 'profit_weight': 2.0},
            ]
            _invoice_with_items(emp.id, items)
            emp_id, cat_id = emp.id, cat.id
            bucket_24 = 4.0 * 24.0 / MAIN_KARAT * 2.0
            bucket_21 = 2.0 * 21.0 / MAIN_KARAT * 2.0
            expected = round(bucket_24 + bucket_21)
            _set_point_rules([PointRule(category_id=cat_id, karat=None, multiplier=2.0)])

        payload = _leaderboard(auth_headers)
        with flask_app.app_context():
            _clear_point_rules()
        assert _score_for(payload, emp_id) == expected

    def test_mixed_categories_each_employee_own_rule(self, auth_headers):
        """Actor A: Gold (21→10, 18→8). Actor B: Bullion (any→2)."""
        with flask_app.app_context():
            emp_a = _employee('EMP-RUL-A')
            emp_b = _employee('EMP-RUL-B')
            cat_gold = _category('GoldMix')
            cat_bullion = _category('BullionMix')
            items_a = [
                {'karat': 21.0, 'category_id': cat_gold.id,    'profit_weight': 5.0},
                {'karat': 18.0, 'category_id': cat_gold.id,    'profit_weight': 2.0},
            ]
            items_b = [
                {'karat': 24.0, 'category_id': cat_bullion.id, 'profit_weight': 4.0},
            ]
            _invoice_with_items(emp_a.id, items_a)
            _invoice_with_items(emp_b.id, items_b)
            aid, bid = emp_a.id, emp_b.id
            cg, cb = cat_gold.id, cat_bullion.id
            exp_a = round(5.0*21/MAIN_KARAT*10 + 2.0*18/MAIN_KARAT*8)
            exp_b = round(4.0*24/MAIN_KARAT*2)
            _set_point_rules([
                PointRule(category_id=cg, karat=21.0, multiplier=10.0),
                PointRule(category_id=cg, karat=18.0, multiplier=8.0),
                PointRule(category_id=cb, karat=None, multiplier=2.0),
            ])

        payload = _leaderboard(auth_headers)
        with flask_app.app_context():
            _clear_point_rules()
        assert _score_for(payload, aid) == exp_a
        assert _score_for(payload, bid) == exp_b

    def test_no_category_rule_falls_to_default(self, auth_headers):
        """Item with category not covered by any rule → DEFAULT_MULTIPLIER."""
        with flask_app.app_context():
            emp = _employee('EMP-RUL-DEF')
            cat_covered = _category('Covered')
            cat_other = _category('Other')
            items = [
                {'karat': 21.0, 'category_id': cat_covered.id, 'profit_weight': 3.0},
                {'karat': 21.0, 'category_id': cat_other.id,   'profit_weight': 2.0},
            ]
            _invoice_with_items(emp.id, items)
            emp_id = emp.id
            covered_id = cat_covered.id
            # covered: 3×21/21×15 = 45; other: 2×21/21×10 (default) = 20 → total 65
            bucket_covered = 3.0 * 21.0 / MAIN_KARAT * 15.0
            bucket_other   = 2.0 * 21.0 / MAIN_KARAT * DEFAULT_MULTIPLIER
            expected = round(bucket_covered + bucket_other)
            _set_point_rules([PointRule(category_id=covered_id, karat=None, multiplier=15.0)])

        payload = _leaderboard(auth_headers)
        with flask_app.app_context():
            _clear_point_rules()
        assert _score_for(payload, emp_id) == expected


# ─── Regression: full scenario ────────────────────────────────────────────────

class TestRegression:
    """3 employees, 3 karats, 2 categories, default rules only.

    Verifies:
    1. Scores match formula.
    2. Ranking order is preserved.
    3. This test must remain green before AND after Phase 2B implementation.
    """

    def test_three_employees_ranking_and_scores(self, auth_headers):
        with flask_app.app_context():
            e1 = _employee('EMP-REG-1')
            e2 = _employee('EMP-REG-2')
            e3 = _employee('EMP-REG-3')

            # e1: 20g at 21k → profit_gold = 20.0 → 200 pts
            inv1 = _invoice_with_items(e1.id, [{'karat': 21.0, 'profit_weight': 20.0}])

            # e2: 15g at 18k + 3g at 24k → profit_gold = 15×18/21 + 3×24/21
            inv2 = _invoice_with_items(e2.id, [
                {'karat': 18.0, 'profit_weight': 15.0},
                {'karat': 24.0, 'profit_weight': 3.0},
            ])

            # e3: 5g at 21k → profit_gold = 5.0 → 50 pts
            inv3 = _invoice_with_items(e3.id, [{'karat': 21.0, 'profit_weight': 5.0}])

            id1, id2, id3 = e1.id, e2.id, e3.id
            exp1 = round(inv1.profit_gold * DEFAULT_MULTIPLIER)
            exp2 = round(inv2.profit_gold * DEFAULT_MULTIPLIER)
            exp3 = round(inv3.profit_gold * DEFAULT_MULTIPLIER)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, id1) == exp1
        assert _score_for(payload, id2) == exp2
        assert _score_for(payload, id3) == exp3

        # e1 must rank above e2 must rank above e3
        ranking = payload.get('ranking') or []
        ids = [r.get('id') for r in ranking]
        assert ids.index(id1) < ids.index(id2)
        assert ids.index(id2) < ids.index(id3)


# ─── profit_cash source tests ────────────────────────────────────────────────

class TestProfitCashSource:
    """points_source='profit_cash': النقاط = profit_cash ÷ cash_amount_per_point."""

    def teardown_method(self):
        with flask_app.app_context():
            _reset_points_source()

    def test_basic_cash_points(self, auth_headers):
        """1000 ريال ربح ÷ 100 = 10 نقاط."""
        with flask_app.app_context():
            emp = _employee('EMP-CASH-BASIC')
            _invoice_cash(emp.id, profit_cash=1000.0)
            emp_id = emp.id
            _set_points_source('profit_cash', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 10.0

    def test_cash_amount_per_point_respected(self, auth_headers):
        """500 ريال ÷ 250 = 2 نقطة."""
        with flask_app.app_context():
            emp = _employee('EMP-CASH-250')
            _invoice_cash(emp.id, profit_cash=500.0)
            emp_id = emp.id
            _set_points_source('profit_cash', cash_amount_per_point=250.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 2.0

    def test_two_invoices_accumulate(self, auth_headers):
        """فاتورتان: 600 + 400 = 1000 ريال ÷ 100 = 10 نقاط."""
        with flask_app.app_context():
            emp = _employee('EMP-CASH-TWO')
            _invoice_cash(emp.id, profit_cash=600.0)
            _invoice_cash(emp.id, profit_cash=400.0)
            emp_id = emp.id
            _set_points_source('profit_cash', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 10.0

    def test_purchase_invoice_included(self, auth_headers):
        """شراء من عميل يُحتسب في مسار profit_cash."""
        with flask_app.app_context():
            emp = _employee('EMP-CASH-BUY')
            _invoice_cash(emp.id, profit_cash=300.0, invoice_type='شراء من عميل')
            emp_id = emp.id
            _set_points_source('profit_cash', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 3.0

    def test_ranking_order_by_cash_points(self, auth_headers):
        """الترتيب صحيح: الأعلى ربحاً أولاً."""
        with flask_app.app_context():
            e_high = _employee('EMP-CASH-HIGH')
            e_low  = _employee('EMP-CASH-LOW')
            _invoice_cash(e_high.id, profit_cash=2000.0)
            _invoice_cash(e_low.id,  profit_cash=500.0)
            id_high, id_low = e_high.id, e_low.id
            _set_points_source('profit_cash', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        ranking = payload.get('ranking') or []
        ids = [r.get('id') for r in ranking]
        assert ids.index(id_high) < ids.index(id_low)

    def test_gold_weight_mode_unaffected(self, auth_headers):
        """التأكد أن gold_weight (الوضع الافتراضي) لا يتأثر بالتغيير."""
        with flask_app.app_context():
            emp = _employee('EMP-GOLD-UNAFFECTED')
            _invoice_with_items(emp.id, [{'karat': 21.0, 'profit_weight': 5.0}])
            emp_id = emp.id
            _reset_points_source()

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 50.0


# ─── sales_amount source tests ───────────────────────────────────────────────

class TestSalesAmountSource:
    """points_source='sales_amount': النقاط = إجمالي الفاتورة ÷ cash_amount_per_point."""

    def teardown_method(self):
        with flask_app.app_context():
            _reset_points_source()

    def test_basic_sales_amount(self, auth_headers):
        """فاتورة 2000 ريال ÷ 100 = 20 نقطة."""
        with flask_app.app_context():
            emp = _employee('EMP-SA-BASIC')
            _invoice_total(emp.id, total=2000.0)
            emp_id = emp.id
            _set_points_source('sales_amount', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 20.0

    def test_divisor_respected(self, auth_headers):
        """3000 ريال ÷ 500 = 6 نقاط."""
        with flask_app.app_context():
            emp = _employee('EMP-SA-DIV')
            _invoice_total(emp.id, total=3000.0)
            emp_id = emp.id
            _set_points_source('sales_amount', cash_amount_per_point=500.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 6.0

    def test_two_invoices_accumulate(self, auth_headers):
        """1500 + 500 = 2000 ÷ 100 = 20 نقطة."""
        with flask_app.app_context():
            emp = _employee('EMP-SA-TWO')
            _invoice_total(emp.id, total=1500.0)
            _invoice_total(emp.id, total=500.0)
            emp_id = emp.id
            _set_points_source('sales_amount', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 20.0

    def test_ranking_order(self, auth_headers):
        """الأعلى مبيعاً يأتي أولاً."""
        with flask_app.app_context():
            e_big = _employee('EMP-SA-BIG')
            e_sml = _employee('EMP-SA-SML')
            _invoice_total(e_big.id, total=5000.0)
            _invoice_total(e_sml.id, total=1000.0)
            id_big, id_sml = e_big.id, e_sml.id
            _set_points_source('sales_amount', cash_amount_per_point=100.0)

        payload = _leaderboard(auth_headers)
        ids = [r.get('id') for r in (payload.get('ranking') or [])]
        assert ids.index(id_big) < ids.index(id_sml)


# ─── invoice_count source tests ──────────────────────────────────────────────

class TestInvoiceCountSource:
    """points_source='invoice_count': النقاط = عدد الفواتير × points_per_invoice."""

    def teardown_method(self):
        with flask_app.app_context():
            _reset_points_source()

    def _set_count_source(self, ppi: float = 1.0):
        settings = Settings.query.first()
        if settings is None:
            settings = Settings()
            db.session.add(settings)
            db.session.flush()
        raw = settings.sales_race_settings
        cfg = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
        cfg['points_source']      = 'invoice_count'
        cfg['points_per_invoice'] = ppi
        settings.sales_race_settings = json.dumps(cfg, ensure_ascii=False)
        db.session.commit()

    def test_one_invoice_one_point(self, auth_headers):
        with flask_app.app_context():
            emp = _employee('EMP-IC-ONE')
            _invoice_total(emp.id, total=0.0)
            emp_id = emp.id
            self._set_count_source(ppi=1.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 1.0

    def test_three_invoices_five_points_each(self, auth_headers):
        """3 فواتير × 5 نقاط = 15 نقطة."""
        with flask_app.app_context():
            emp = _employee('EMP-IC-THREE')
            for _ in range(3):
                _invoice_total(emp.id, total=100.0)
            emp_id = emp.id
            self._set_count_source(ppi=5.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 15.0

    def test_purchase_counts(self, auth_headers):
        """شراء من عميل يُحتسب في عدد الفواتير."""
        with flask_app.app_context():
            emp = _employee('EMP-IC-BUY')
            _invoice_total(emp.id, total=0.0, invoice_type='شراء من عميل')
            _invoice_total(emp.id, total=0.0, invoice_type='شراء من عميل')
            emp_id = emp.id
            self._set_count_source(ppi=3.0)

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 6.0

    def test_ranking_order(self, auth_headers):
        """الأكثر فواتير يأتي أولاً."""
        with flask_app.app_context():
            e_many = _employee('EMP-IC-MANY')
            e_few  = _employee('EMP-IC-FEW')
            for _ in range(5):
                _invoice_total(e_many.id, total=0.0)
            _invoice_total(e_few.id, total=0.0)
            id_many, id_few = e_many.id, e_few.id
            self._set_count_source(ppi=1.0)

        payload = _leaderboard(auth_headers)
        ids = [r.get('id') for r in (payload.get('ranking') or [])]
        assert ids.index(id_many) < ids.index(id_few)


# ─── sold_weight source tests ────────────────────────────────────────────────

class TestSoldWeightSource:
    """points_source='sold_weight': النقاط = الوزن المباع × points_per_gram."""

    def teardown_method(self):
        with flask_app.app_context():
            _reset_points_source()

    def test_basic_sold_weight(self, auth_headers):
        """10 جرام مباعة × 10 = 100 نقطة."""
        with flask_app.app_context():
            emp = _employee('EMP-SW-BASIC')
            _invoice_with_weight(emp.id, weight_g=10.0)
            emp_id = emp.id
            _set_points_source('sold_weight')

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 100.0

    def test_multiple_items_accumulate(self, auth_headers):
        """فاتورتان: 6 + 4 = 10 جرام × 10 = 100 نقطة."""
        with flask_app.app_context():
            emp = _employee('EMP-SW-TWO')
            _invoice_with_weight(emp.id, weight_g=6.0)
            _invoice_with_weight(emp.id, weight_g=4.0)
            emp_id = emp.id
            _set_points_source('sold_weight')

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 100.0

    def test_ignores_profit_weight(self, auth_headers):
        """في sold_weight، profit_weight=0 لا يؤثر — يُستخدم weight فقط."""
        with flask_app.app_context():
            emp = _employee('EMP-SW-NOPW')
            _invoice_with_weight(emp.id, weight_g=5.0)
            emp_id = emp.id
            _set_points_source('sold_weight')

        payload = _leaderboard(auth_headers)
        assert _score_for(payload, emp_id) == 50.0

    def test_ranking_order(self, auth_headers):
        """الأثقل وزناً يأتي أولاً."""
        with flask_app.app_context():
            e_heavy = _employee('EMP-SW-HEAVY')
            e_light = _employee('EMP-SW-LIGHT')
            _invoice_with_weight(e_heavy.id, weight_g=20.0)
            _invoice_with_weight(e_light.id, weight_g=3.0)
            id_heavy, id_light = e_heavy.id, e_light.id
            _set_points_source('sold_weight')

        payload = _leaderboard(auth_headers)
        ids = [r.get('id') for r in (payload.get('ranking') or [])]
        assert ids.index(id_heavy) < ids.index(id_light)
