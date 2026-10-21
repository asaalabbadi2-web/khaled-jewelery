"""
وظيفة التسوية الشهرية لمشتريات الذهب — gate tests.

استعلامان ومقارنة:
  Q1 (بسط avg_buy):  customer_purchases + settlement_purchases − customer_buy_returns
  Q2 (JE-based):      sum(cash_credit − cash_debit) على سطور قيود تشير إلى فواتير Q1
  التباين = Q2 − Q1

Month registry (2099):  months 9-12 reserved for this file.
  M_CLEAN    = 9  — clean path: invoice + JE → discrepancy = 0
  M_MISSING  = 10 — missing JE: posted invoice, no JE → discrepancy < 0
  M_SUPPLIER = 11 — supplier bypass: new-gold invoice visible but excluded from Q1
  M_RETURNS  = 12 — returns: purchase + return + matching JEs → discrepancy = 0

Running:
    cd backend && pytest test_gold_acquisition_reconciliation.py -v
"""
import calendar
import pytest
from datetime import datetime

from app import app
from models import (
    db,
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


CASH_ACCOUNT_ID = 15    # صندوق النقدية — seeded in conftest.py
# A stock account that tracks weight -- seeded in conftest.py. It was 1220,
# which the P4.2 migration (ADR-026) made a financial account (cash, no
# weight): the unlinked-entry path reads weight accounts, so it saw nothing.
GOLD_ACCOUNT_ID = 1300  # مخزون ذهب معروض للبيع (موحد), tracks_weight=True

# ── Month registry ────────────────────────────────────────────────────────────
M_CLEAN    = 9
M_MISSING  = 10
M_SUPPLIER = 11
M_RETURNS  = 12
M_MANUAL   = 1   # test_unlinked_manual_je_detected — uses year=2100 to avoid collision
# ─────────────────────────────────────────────────────────────────────────────

# Invoice_type_id counter — offset must not collide with other test files:
#   gram_profit tests: 800000+
#   settlement tests: 900000+
#   reconciliation: 700000+
_inv_counter = [700000]


def _period(month: int, year: int = 2099):
    _, last = calendar.monthrange(year, month)
    start = f'{year}-{month:02d}-01'
    end   = f'{year}-{month:02d}-{last:02d}'
    dt    = datetime(year, month, 15)
    url   = (
        f'/api/reports/gold_acquisition_reconciliation'
        f'?start_date={start}&end_date={end}'
    )
    return dt, url


def _inv(invoice_type, total, weight_g, inv_date, gold_type=None, is_posted=True):
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
        karat=21.0,
        weight_grams=float(weight_g),
    ))
    db.session.flush()
    return inv


def _je(invoice, cash_credit=0.0, cash_debit=0.0):
    """Post a minimal JournalEntry referencing *invoice* with one cash line."""
    je = JournalEntry(
        date=invoice.date,
        description='test-je',
        reference_type='invoice',
        reference_id=invoice.id,
        is_posted=True,
        is_deleted=False,
    )
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(
        journal_entry_id=je.id,
        account_id=CASH_ACCOUNT_ID,
        cash_credit=cash_credit,
        cash_debit=cash_debit,
    ))
    db.session.flush()
    return je


def _fetch(url, auth_headers):
    with app.test_client() as client:
        resp = client.get(url, headers=auth_headers)
    body = resp.get_data(as_text=True)
    assert resp.status_code == 200, f"HTTP {resp.status_code}: {body}"
    return resp.get_json()


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_clean_zero_discrepancy(auth_headers):
    """
    [1] Scrap purchase + customer purchase each with a matching posted JE →
    Q1 and Q2 agree, discrepancy = 0, is_clean = True.
    """
    dt, url = _period(M_CLEAN)
    with app.app_context():
        scrap = _inv('شراء', 5000.0, 10.0, dt, gold_type='scrap')
        customer = _inv('شراء من عميل', 3000.0, 6.0, dt)
        _je(scrap,    cash_credit=5000.0)
        _je(customer, cash_credit=3000.0)
        db.session.commit()

    d = _fetch(url, auth_headers)

    assert d['is_clean'] is True, f"is_clean=False, discrepancy={d['discrepancy']}"
    assert abs(d['discrepancy']) < 0.01, f"discrepancy={d['discrepancy']}"
    assert abs(d['avg_buy_path']['avg_buy_numerator'] - 8000.0) < 0.01
    assert abs(d['je_path']['je_net_cash'] - 8000.0) < 0.01
    assert d['avg_buy_path']['settlement_purchases_count'] == 1
    assert d['avg_buy_path']['customer_purchases_count'] == 1


def test_missing_je_detected(auth_headers):
    """
    [2] Customer purchase posted with no JE → Q2 = 0 while Q1 > 0.
    discrepancy = -invoice_total (negative = invoice without JE).
    is_clean = False.
    """
    dt, url = _period(M_MISSING)
    with app.app_context():
        _inv('شراء من عميل', 4000.0, 8.0, dt)
        # intentionally no _je() call
        db.session.commit()

    d = _fetch(url, auth_headers)

    assert d['is_clean'] is False, "Expected is_clean=False for missing JE"
    assert abs(d['discrepancy'] - (-4000.0)) < 0.01, f"discrepancy={d['discrepancy']}"
    assert abs(d['avg_buy_path']['avg_buy_numerator'] - 4000.0) < 0.01
    assert abs(d['je_path']['je_net_cash']) < 0.01


def test_supplier_purchase_visible_not_in_q1(auth_headers):
    """
    [3] Supplier (new-gold) purchase with a posted JE.
    Q1 = 0 (supplier excluded from avg_buy), Q2 = 0 (supplier invoice not
    in all_relevant_ids), discrepancy = 0.
    supplier_purchases.cash is positive and note is set — the data is surfaced
    for manual review, not flagged as a Q1/Q2 inconsistency.
    """
    dt, url = _period(M_SUPPLIER)
    with app.app_context():
        supplier_inv = _inv('شراء', 9000.0, 15.0, dt, gold_type='new')
        _je(supplier_inv, cash_credit=9000.0)
        db.session.commit()

    d = _fetch(url, auth_headers)

    assert d['is_clean'] is True, f"Unexpected discrepancy={d['discrepancy']}"
    assert abs(d['discrepancy']) < 0.01
    assert abs(d['avg_buy_path']['avg_buy_numerator']) < 0.01, "Supplier leaked into Q1"
    assert d['supplier_purchases']['cash'] > 0, "Supplier cash not surfaced"
    assert d['supplier_purchases']['note'] is not None, "Supplier note missing"


def test_returns_cancel_cleanly(auth_headers):
    """
    [4] Scrap purchase + customer return, each with a matching JE.
    avg_buy_numerator = purchase - return.
    je_net_cash = cash_credit(purchase) - cash_debit(return).
    discrepancy = 0.
    """
    dt, url = _period(M_RETURNS)
    with app.app_context():
        purchase = _inv('شراء من عميل', 6000.0, 12.0, dt)
        ret      = _inv('مرتجع شراء',  2000.0,  4.0, dt)
        _je(purchase, cash_credit=6000.0)
        _je(ret,      cash_debit=2000.0)   # cash coming back = debit on cash account
        db.session.commit()

    d = _fetch(url, auth_headers)

    expected_numerator = 6000.0 - 2000.0  # 4000
    assert d['is_clean'] is True, f"is_clean=False, discrepancy={d['discrepancy']}"
    assert abs(d['discrepancy']) < 0.01
    assert abs(d['avg_buy_path']['avg_buy_numerator'] - expected_numerator) < 0.01, (
        f"avg_buy_numerator={d['avg_buy_path']['avg_buy_numerator']}"
    )
    assert abs(d['je_path']['je_net_cash'] - expected_numerator) < 0.01
    assert d['avg_buy_path']['customer_buy_returns_count'] == 1


def test_unlinked_manual_je_detected(auth_headers):
    """
    [5] قيد يدوي (سند صرف مباشر) يدين حساب مخزون ذهب ويدين النقدية —
    بلا فاتورة، بلا reference_type='invoice'.

    Q1 = 0 (لا فاتورة خردة).
    Q2 يجب أن يرصد القيد عبر المسار القائم على الحسابات، لا عبر معرّفات الفواتير.
    التباين = cash_credit القيد، is_clean = False.

    الفشل الحالي هو الشاهد: Q2 مقيَّد بمعرّفات Q1 فلن يرى هذا القيد.
    النجاح يتطلب توسيع نطاق Q2 لفحص حسابات اقتناء الذهب.
    """
    dt, url = _period(M_MANUAL, year=2100)
    with app.app_context():
        je = JournalEntry(
            date=dt,
            description='سند صرف مباشر — شراء ذهب بلا فاتورة',
            is_posted=True,
            is_deleted=False,
            # reference_type intentionally None — no invoice in the system
        )
        db.session.add(je)
        db.session.flush()
        # Gold inventory debit — signal: gold was acquired
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id,
            account_id=GOLD_ACCOUNT_ID,
            debit_21k=10.0,
        ))
        # Cash credit — cash went out
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id,
            account_id=CASH_ACCOUNT_ID,
            cash_credit=5000.0,
        ))
        db.session.commit()

    d = _fetch(url, auth_headers)

    assert d['is_clean'] is False, (
        "Expected is_clean=False — unlinked gold JE must surface as discrepancy"
    )
    assert abs(d['discrepancy'] - 5000.0) < 0.01, f"discrepancy={d['discrepancy']}"
    assert abs(d['je_path']['unlinked_gold_cash'] - 5000.0) < 0.01, (
        f"unlinked_gold_cash={d['je_path'].get('unlinked_gold_cash')}"
    )
    assert abs(d['avg_buy_path']['avg_buy_numerator']) < 0.01
