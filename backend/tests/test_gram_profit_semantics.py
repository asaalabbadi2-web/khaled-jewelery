"""
ADR-024 § Proof — gram profit semantics gate.

Tests 1-6: guard existing correct behavior (no code changes required).
Test 7: D-1 retired by ADR-048 (a period with no purchase is counted); test 8: D-3, fixed.

Running:
    cd backend && pytest test_gram_profit_semantics.py -v

For PostgreSQL:
    PYTEST_ALLOW_REAL_DB=1 pytest test_gram_profit_semantics.py -v
    Requires DATABASE_URL pointing to a dedicated test DB, not production.

Session-isolation model
    Each test owns its own calendar month (2099-MM) so committed data from one
    test never appears in another's date-range query.  Data is committed (not
    flushed-then-rolled-back) because the HTTP request runs in a separate
    Flask app-context and can only see committed rows.  The SQLite file is
    fresh per pytest session (conftest.py timestamp+pid filename), so data
    accumulated across tests within one session is harmless as long as the
    month ranges are unique.
"""
import calendar
import pytest
from datetime import datetime

from accounting.chart_tree import REVENUE_ROOT, role_account_id
from app import app
from models import (
    db,
    Account,
    Invoice,
    InvoiceKaratLine,
    JournalEntry,
    JournalEntryLine,
)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield


MAIN_KARAT = 21

# ── Month registry — MANDATORY RULE ──────────────────────────────────────────
# Each test owns exactly one calendar month in 2099.  A month collision is
# silent: it inflates avg_buy in the polluted test and produces a confusing
# failure far from the root cause.
#
# To add a test: pick the next unused month, add a constant here, use it in
# _period(M_<YOUR_TEST>).  Never reuse a month.  If this file grows beyond
# ~20 tests, switch to per-test transaction rollback instead.
#
M_SUPPLIER  = 1   # test_supplier_invoices_never_enter_avg_buy
M_UNPOSTED  = 2   # test_unposted_invoices_excluded_from_all_inputs
M_RETURNS   = 3   # test_returns_subtracted_from_both_numerator_and_denominator
M_KARAT     = 4   # test_weight_normalized_to_main_karat
M_FLAGS     = 5   # test_flags_do_not_affect_avg_buy
M_FORMULA   = 6   # test_net_profit_weight_equals_sum_of_four_layers
M_D1        = 7   # test_a_period_with_no_purchase_is_counted_not_unavailable  [D-1 retired, ADR-048]
M_D3        = 8   # test_d3_grandchild_of_741_not_double_counted     [xfail D-3]
# M_NEXT    = 9   # ← next available month for new tests
# ─────────────────────────────────────────────────────────────────────────────

# UniqueConstraint on (invoice_type, invoice_type_id) — must be unique across
# the entire test session.  High offset avoids collision with:
#   test_allocation_service_invariant.py  → starts from 1
#   test_settlement_state_service.py      → starts from 900001
_inv_counter = [800000]

# ── مجموعة مفاتيح الاستجابة المتوقعة (مصدر وحيد) ──────────────────────────────
# حقل يُضاف إلى routes/reports.py يجب أن يُضاف هنا أيضاً.
# حقل يُضاف إلى الفرع الأول (avg_buy > 0) بلا إضافة مقابلة في الفرع الثاني
# يُنتج مفتاحاً مفقوداً في حالة D-1 — يرصده assertion في test 6 و test 7.
GRAM_PROFIT_RESPONSE_KEYS = frozenset({
    # metadata
    'start_date', 'end_date', 'report_type', 'main_karat',
    # Layer ① — always numeric
    'weight_sold', 'weight_purchased', 'weight_purchased_customer',
    'weight_purchased_supplier',
    'avg_sell_per_gram', 'avg_buy_per_gram', 'margin_per_gram',
    'trading_profit_cash', 'trading_profit_weight',
    'total_sales_cash', 'total_purchases_cash',
    'customer_purchases_cash', 'settlement_purchases_cash',
    'settlement_weight_purchased', 'supplier_purchases_cash',
    'supplier_weight_purchased',
    # Layer ② — extra_revenue_weight always numeric; rest nullable when avg_buy=0
    'extra_revenue_weight', 'extra_revenue_cash',
    'extra_revenue_cash_as_weight', 'total_extra_revenue_weight',
    'extra_revenue_details',
    # Layer ③ — always numeric
    'expense_weight_direct', 'expense_weight_details',
    # Layer ④ — expense_cash_total always numeric; expense_cash_as_weight nullable
    'expense_cash_total', 'expense_cash_as_weight', 'expense_cash_details',
    # Results — nullable when avg_buy=0
    'gross_profit', 'gross_profit_weight',
    'net_profit', 'net_profit_weight', 'net_margin_pct',
    # Backward-compat fields — nullable when avg_buy=0
    'manufacturing_wages', 'other_expenses',
    'total_operating_expenses', 'profit_after_wages', 'profit_after_wages_weight',
    # Availability signal -- always None since ADR-048
    'unavailable_reason',
    # The weight position engine's fifth layer and its valuation (ADR-048 phase 2b)
    'price_effect_weight', 'realized_weight', 'unrealized_start_weight', 'unrealized_end_weight',
    'valuation_price_per_gram', 'valuation_price_source',
})


# ── helpers ───────────────────────────────────────────────────────────────────

def _period(month: int):
    """Each test owns one unique calendar month → no cross-test pollution."""
    _, last = calendar.monthrange(2099, month)
    start  = f'2099-{month:02d}-01'
    end    = f'2099-{month:02d}-{last:02d}'
    inv_dt = datetime(2099, month, 15)
    url    = f'/api/reports/gram_profit?start_date={start}&end_date={end}'
    return inv_dt, url


def _inv(invoice_type, total, weight_g, inv_date,
         karat=MAIN_KARAT, is_posted=True, gold_type=None):
    """Create Invoice + one InvoiceKaratLine and flush (caller commits)."""
    _inv_counter[0] += 1
    inv = Invoice(
        invoice_type=invoice_type,
        invoice_type_id=_inv_counter[0],
        date=inv_date,
        total=total,
        is_posted=is_posted,
        gold_type=gold_type,
    )
    db.session.add(inv)
    db.session.flush()
    db.session.add(InvoiceKaratLine(
        invoice_id=inv.id,
        karat=float(karat),
        weight_grams=float(weight_g),
    ))
    return inv


def _sell(inv_date, total, weight_g, karat=MAIN_KARAT, is_posted=True):
    return _inv('بيع', total, weight_g, inv_date, karat=karat, is_posted=is_posted)

def _buy_customer(inv_date, total, weight_g, karat=MAIN_KARAT, is_posted=True):
    return _inv('شراء من عميل', total, weight_g, inv_date, karat=karat, is_posted=is_posted)

def _buy_scrap(inv_date, total, weight_g, karat=MAIN_KARAT, is_posted=True):
    return _inv('شراء', total, weight_g, inv_date, karat=karat,
                is_posted=is_posted, gold_type='scrap')

def _buy_supplier(inv_date, total, weight_g, karat=MAIN_KARAT, is_posted=True):
    return _inv('شراء', total, weight_g, inv_date, karat=karat,
                is_posted=is_posted, gold_type='new')

def _buy_return(inv_date, total, weight_g, karat=MAIN_KARAT, is_posted=True):
    return _inv('مرتجع شراء', total, weight_g, inv_date, karat=karat, is_posted=is_posted)


def _fetch(url, auth_headers):
    """Make a GET request in an isolated app context and return the JSON body."""
    with app.test_client() as client:
        resp = client.get(url, headers=auth_headers)
    body = resp.get_data(as_text=True)
    assert resp.status_code == 200, f"HTTP {resp.status_code}: {body}"
    return resp.get_json()


# ── Tests 1-6: guard correct behaviour ────────────────────────────────────────

def test_supplier_invoices_never_enter_avg_buy(auth_headers):
    """
    [1] avg_buy is computed from scrap purchases only — supplier invoices excluded.

    Scrap:    5100 SAR / 10g → avg_buy expected = 510.
    Supplier: 5980 SAR / 10g — must not change avg_buy.
    """
    inv_dt, url = _period(M_SUPPLIER)
    with app.app_context():
        _buy_scrap(inv_dt, 5100.0, 10.0)
        _buy_supplier(inv_dt, 5980.0, 10.0)
        db.session.commit()

    d = _fetch(url, auth_headers)
    assert abs(d['avg_buy_per_gram'] - 510.0) < 0.5, (
        f"avg_buy={d['avg_buy_per_gram']} — supplier purchases leaked into avg_buy"
    )
    assert abs(d['settlement_purchases_cash'] - 5100.0) < 0.1


def test_unposted_invoices_excluded_from_all_inputs(auth_headers):
    """
    [2] Unposted invoices (is_posted=False) are excluded from avg_buy,
        weight_sold, and all four layers.
    """
    inv_dt, url = _period(M_UNPOSTED)
    with app.app_context():
        _buy_scrap(inv_dt, 5100.0, 10.0, is_posted=False)
        _sell(inv_dt, 8000.0, 15.0, is_posted=False)
        db.session.commit()

    d = _fetch(url, auth_headers)
    assert d['avg_buy_per_gram'] == 0.0, f"avg_buy={d['avg_buy_per_gram']}"
    assert d['weight_sold']       == 0.0, f"weight_sold={d['weight_sold']}"


def test_returns_subtracted_from_both_numerator_and_denominator(auth_headers):
    """
    [3] A purchase return subtracts from both numerator and denominator of avg_buy.

    Buy 10g at 5100, return 5g at 2550
    → cash_for_gold = 2550, weight = 5g, avg_buy = 510.
    """
    inv_dt, url = _period(M_RETURNS)
    with app.app_context():
        _buy_customer(inv_dt, 5100.0, 10.0)
        _buy_return(inv_dt, 2550.0, 5.0)
        db.session.commit()

    d = _fetch(url, auth_headers)
    assert abs(d['customer_purchases_cash'] - 2550.0) < 0.1, (
        f"customer_purchases_cash={d['customer_purchases_cash']}"
    )
    assert abs(d['avg_buy_per_gram'] - 510.0) < 0.5, (
        f"avg_buy={d['avg_buy_per_gram']}"
    )


def test_weight_normalized_to_main_karat(auth_headers):
    """
    [4] Invoice weights are normalized to main_karat (21K) before aggregation.

    100g@18K + 100g@22K raw = 200g
    → MK-normalized = (100×18/21) + (100×22/21) ≈ 190.476g ≠ 200g.
    """
    inv_dt, url = _period(M_KARAT)
    with app.app_context():
        _buy_scrap(inv_dt, 4500.0, 100.0, karat=18)
        _buy_scrap(inv_dt, 5500.0, 100.0, karat=22)
        db.session.commit()

    d = _fetch(url, auth_headers)
    expected_mk = 100.0 * 18 / MAIN_KARAT + 100.0 * 22 / MAIN_KARAT   # ≈ 190.476
    mk_weight   = d['settlement_weight_purchased']
    assert abs(mk_weight - 200.0) > 0.1, (
        f"Normalization absent: {mk_weight}g equals raw sum 200g"
    )
    assert abs(mk_weight - expected_mk) < 0.01, (
        f"MK weight {mk_weight} ≠ expected {expected_mk}"
    )


def test_flags_do_not_affect_avg_buy(auth_headers):
    """
    [5] include_in_gram_profit on an account feeds Layers ②③④ only — never avg_buy.
    """
    inv_dt, url = _period(M_FLAGS)
    with app.app_context():
        flagged = Account.query.filter_by(account_number='49900').first()
        if flagged is None:
            flagged = Account(
                account_number='49900',
                name='إيرادات اختبار ربح الجرام',
                type='Revenue',
                tracks_weight=False,
                include_in_gram_profit=True,
                # A marked account is a revenue by the tree, under the revenue
                # group (CHART-002) -- not by its number; alone it counts nowhere.
                parent_id=role_account_id(REVENUE_ROOT),
            )
            db.session.add(flagged)
            db.session.flush()

        cash_acc = Account.query.filter_by(id=15).first()   # seeded in conftest
        _inv_counter[0] += 1
        je = JournalEntry(
            entry_number=f'TEST-GP5-{_inv_counter[0]}',
            date=inv_dt,
            is_posted=True,
        )
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id,
            account_id=cash_acc.id,
            cash_debit=1000.0,
        ))
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id,
            account_id=flagged.id,
            cash_credit=1000.0,
        ))
        _buy_scrap(inv_dt, 5100.0, 10.0)
        db.session.commit()

    d = _fetch(url, auth_headers)
    # avg_buy must be 5100/10 = 510; the flagged account must not affect it
    assert abs(d['avg_buy_per_gram'] - 510.0) < 0.5, (
        f"avg_buy={d['avg_buy_per_gram']} — flagged account affected avg_buy"
    )
    assert d['extra_revenue_cash'] > 0, (
        "extra_revenue_cash must reflect the 1000 SAR credit on the flagged account"
    )


def test_net_profit_weight_equals_sum_of_four_layers(auth_headers):
    """
    [6] Fundamental formula (contract): the five layers of the weight position
        engine (ADR-048 phase 2b, 5eaecd73) -- ① + ② - ③ - ④ + ⑤, the price
        effect on what still waits to be turned into gold. It was four.
    """
    inv_dt, url = _period(M_FORMULA)
    with app.app_context():
        _sell(inv_dt, 10500.0, 20.0)
        _buy_scrap(inv_dt, 5100.0, 10.0)
        db.session.commit()

    d = _fetch(url, auth_headers)
    computed = (
        d['trading_profit_weight']
      + d['total_extra_revenue_weight']
      - d['expense_weight_direct']
      - d['expense_cash_as_weight']
      + d['price_effect_weight']
    )
    assert abs(d['net_profit_weight'] - computed) < 0.002, (
        f"Formula broken: net={d['net_profit_weight']} ≠ Σlayers={computed}"
    )
    # مجموعة المفاتيح في الحالة العادية — تُقارن بها حالة D-1
    assert set(d.keys()) == GRAM_PROFIT_RESPONSE_KEYS, (
        f"keys mismatch (normal) — extra: {set(d.keys()) - GRAM_PROFIT_RESPONSE_KEYS}, "
        f"missing: {GRAM_PROFIT_RESPONSE_KEYS - set(d.keys())}"
    )


# ── Tests 7-8: deviation witnesses (xfail strict) ─────────────────────────────

def test_a_period_with_no_purchase_is_counted_not_unavailable(auth_headers):
    """
    [7] D-1 is no more (ADR-048: «ولا "غير متوفر" بعد اليوم -- يناير يُحسب»):
    the engine values what waits at the shop's own buying price, so a period
    with sales and no purchase is counted. It pinned null and 'no_cash_purchases'.
    """
    inv_dt, url = _period(M_D1)
    with app.app_context():
        _sell(inv_dt, 10000.0, 20.0)   # sales with no purchases
        db.session.commit()

    d = _fetch(url, auth_headers)
    assert d.get('unavailable_reason') is None
    assert isinstance(d['net_profit_weight'], (int, float))
    assert d['weight_sold'] == pytest.approx(20.0, abs=0.01)
    assert d['total_sales_cash'] == pytest.approx(10000.0, abs=0.01)
    assert set(d.keys()) == GRAM_PROFIT_RESPONSE_KEYS, (
        f"keys mismatch -- extra: {set(d.keys()) - GRAM_PROFIT_RESPONSE_KEYS}, "
        f"missing: {GRAM_PROFIT_RESPONSE_KEYS - set(d.keys())}"
    )


def test_d3_grandchild_of_741_not_double_counted(auth_headers):
    """
    [8] D-3 مُصلَح: الحساب الحفيد (74111) ضمن مجموعة المقابلات 741
               يجب ألّا يدخل الطبقة ②.

    741 → 7411 → 74111
    الإصلاح: _collect_counterpart_descendants() تجمع كل المنحدرين بشكل مُعادي
    — الفلتر الضحل (parent_id مستوى واحد) استُبدل في نفس الـ commit.
    """
    inv_dt, url = _period(M_D3)
    with app.app_context():
        p741 = Account.query.filter_by(account_number='741').first()
        if p741 is None:
            p741 = Account(account_number='741', name='مقابلات المبيعات الوزنية',
                           type='Revenue', tracks_weight=True)
            db.session.add(p741)
            db.session.flush()

        c7411 = Account.query.filter_by(account_number='7411').first()
        if c7411 is None:
            c7411 = Account(account_number='7411', name='مبيعات ذهب عيار 21 (وزن)',
                            type='Revenue', tracks_weight=True, parent_id=p741.id)
            db.session.add(c7411)
            db.session.flush()

        gc74111 = Account.query.filter_by(account_number='74111').first()
        if gc74111 is None:
            gc74111 = Account(account_number='74111', name='مبيعات ذهب عيار 21 (فرع)',
                              type='Revenue', tracks_weight=True, parent_id=c7411.id)
            db.session.add(gc74111)
            db.session.flush()

        # Gold credit 5g@21K on the grandchild — should be excluded by the fix
        _inv_counter[0] += 1
        je = JournalEntry(
            entry_number=f'TEST-GP8-{_inv_counter[0]}',
            date=inv_dt,
            is_posted=True,
        )
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id,
            account_id=gc74111.id,
            credit_21k=5.0,
        ))

        # Provide a real avg_buy so D-1 does not obscure the D-3 signal
        _buy_scrap(inv_dt, 5100.0, 10.0)
        _sell(inv_dt, 10500.0, 20.0)
        db.session.commit()

    d = _fetch(url, auth_headers)
    # Target: 0.0 — current: 5.0 (bug) → assertion fails → xfail
    assert d['extra_revenue_weight'] == 0.0, (
        f"74111 leaked: extra_revenue_weight={d['extra_revenue_weight']}"
    )
