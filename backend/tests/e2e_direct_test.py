"""
E2E test via Flask test client — no server restart needed.
Tests: بيع, شراء من عميل, مرتجع بيع, مرتجع شراء, COGS weight-closing
"""
import os
import sys
import json
from datetime import date

# تفعيل bypass المصادقة لبيئة الاختبار حتى يعمل test client بدون token
os.environ.setdefault('BYPASS_AUTH_FOR_DEVELOPMENT', '1')

import app as flask_app
from models import db, JournalEntryLine, JournalEntry, Account, WeightClosingOrder

PASS = "✅"
FAIL = "❌"
errors = []


def ok(msg):
    print(f"  {PASS} {msg}")


def fail(msg):
    print(f"  {FAIL} {msg}")
    errors.append(msg)


def section(title):
    print(f"\n{'─'*60}")
    print(f"  {title}")
    print(f"{'─'*60}")


def get_je_lines_db(je_id):
    lines = JournalEntryLine.query.filter_by(journal_entry_id=je_id).all()
    return [
        {
            "account_id": l.account_id,
            "cash_debit": float(l.cash_debit or 0),
            "cash_credit": float(l.cash_credit or 0),
            "debit_21k": float(l.debit_21k or 0),
            "credit_21k": float(l.credit_21k or 0),
        }
        for l in lines
    ]


def check_je_balance(je_id, label):
    lines = get_je_lines_db(je_id)
    cd = sum(l["cash_debit"] for l in lines)
    cc = sum(l["cash_credit"] for l in lines)
    wd = sum(l["debit_21k"] for l in lines)
    wc = sum(l["credit_21k"] for l in lines)
    cash_ok = abs(cd - cc) < 0.05
    weight_ok = abs(wd - wc) < 0.005

    print(f"  JE {je_id}: {len(lines)} lines")
    for l in lines:
        a_num = getattr(Account.query.get(l["account_id"]), "account_number", "?")
        print(f"    acc={l['account_id']:>6} ({a_num:>12}) cd={l['cash_debit']:>10.2f} cc={l['cash_credit']:>10.2f} d21={l['debit_21k']:>8.4f} c21={l['credit_21k']:>8.4f}")

    if cash_ok:
        ok(f"{label}: cash balanced (debit={cd:.2f}, credit={cc:.2f})")
    else:
        fail(f"{label}: cash UNBALANCED (debit={cd:.2f}, credit={cc:.2f})")
    if weight_ok:
        ok(f"{label}: weight balanced (debit={wd:.4f}g, credit={wc:.4f}g)")
    else:
        fail(f"{label}: weight UNBALANCED (debit={wd:.4f}g, credit={wc:.4f}g)")

    # Check that no SINGLE LINE contains both cash and weight values simultaneously.
    # (A given account may appear in multiple lines — one cash-only, one weight-only — which is valid.)
    mixed_line = None
    for l in lines:
        line_has_cash = float(l["cash_debit"]) > 0 or float(l["cash_credit"]) > 0
        line_has_weight = float(l["debit_21k"]) > 0 or float(l["credit_21k"]) > 0
        if line_has_cash and line_has_weight:
            mixed_line = l
            break
    if mixed_line:
        fail(f"{label}: single JE line mixes cash+weight (account_id={mixed_line['account_id']})")
        return
    ok(f"{label}: no weight on cash accounts")
    return lines


with flask_app.app.test_client() as c:
    # Load gold price first
    gp_resp = json.loads(c.get('/api/gold_price').data)
    gp = float(gp_resp.get("price_main_karat", 491.93))
    print(f"Gold price: {gp} SAR/g (21k)")

    # ─── TEST 1: بيع ────────────────────────────────────────────────────────
    section("TEST 1: فاتورة بيع")
    unit_price = round(gp * 11 + 900, 2)
    r1 = c.post('/api/invoices', json={
        "invoice_type": "بيع",
        "customer_id": 1,
        "gold_price": gp,
        "items": [{"item_id": 1, "quantity": 1, "weight": 11.0, "karat": "21", "unit_price": unit_price, "manufacturing_wage": 900.0}],
        "payments": [{"payment_method_id": 1, "amount": unit_price, "safe_box_id": 1}],
        "total": unit_price,
    })
    d1 = json.loads(r1.data)
    if r1.status_code in (200, 201):
        inv_id1 = d1.get("id")
        ok(f"Invoice created: ID={inv_id1} total={unit_price}")
        je1 = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv_id1).first()
        if je1:
            with flask_app.app.app_context():
                check_je_balance(je1.id, "بيع")
        else:
            fail("JE not found for sale invoice")
        SALE_INV_ID = inv_id1
    else:
        fail(f"بيع failed: {r1.status_code} {d1}")
        SALE_INV_ID = None

    # ─── TEST 2: شراء من عميل ───────────────────────────────────────────────
    section("TEST 2: شراء من عميل")
    buy_weight = 8.5
    buy_price = round(gp * 0.9, 2)
    buy_total = round(buy_price * buy_weight, 2)
    r2 = c.post('/api/invoices', json={
        "invoice_type": "شراء من عميل",
        "customer_id": 1,
        "gold_price": gp,
        "gold_type": "scrap",
        "items": [{"weight": buy_weight, "karat": "21", "unit_price": buy_price, "quantity": 1, "name": "ذهب E2E"}],
        "payments": [{"payment_method_id": 1, "amount": buy_total, "safe_box_id": 1}],
        "total": buy_total,
    })
    d2 = json.loads(r2.data)
    if r2.status_code in (200, 201):
        inv_id2 = d2.get("id")
        ok(f"Invoice created: ID={inv_id2} total={buy_total}")
        je2 = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv_id2).first()
        if je2:
            check_je_balance(je2.id, "شراء من عميل")
        else:
            fail("JE not found for cust-buy invoice")
        CUST_BUY_INV_ID = inv_id2
    else:
        fail(f"شراء من عميل failed: {r2.status_code} {json.dumps(d2, ensure_ascii=False)[:300]}")
        CUST_BUY_INV_ID = None

    # ─── TEST 3: مرتجع بيع ──────────────────────────────────────────────────
    section("TEST 3: مرتجع بيع")
    if SALE_INV_ID:
        # Fetch original invoice item IDs
        from models import InvoiceItem
        orig_items = InvoiceItem.query.filter_by(invoice_id=SALE_INV_ID).all()
        orig_item_id = orig_items[0].id if orig_items else None
        r3 = c.post('/api/invoices', json={
            "invoice_type": "مرتجع بيع",
            "customer_id": 1,
            "original_invoice_id": SALE_INV_ID,
            "gold_price": gp,
            "items": [{"item_id": 1, "original_invoice_item_id": orig_item_id, "quantity": 1, "weight": 11.0, "karat": "21", "unit_price": unit_price, "manufacturing_wage": 900.0}],
            "payments": [{"payment_method_id": 1, "amount": unit_price, "safe_box_id": 1}],
            "total": unit_price,
        })
        d3 = json.loads(r3.data)
        if r3.status_code in (200, 201):
            inv_id3 = d3.get("id")
            ok(f"Invoice created: ID={inv_id3}")
            je3 = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv_id3).first()
            if je3:
                check_je_balance(je3.id, "مرتجع بيع")
            else:
                fail("JE not found for sale return")
        else:
            fail(f"مرتجع بيع failed: {r3.status_code} {json.dumps(d3, ensure_ascii=False)[:300]}")
    else:
        print("  ⏭  Skipped (no sale invoice)")

    # ─── TEST 4: مرتجع شراء ─────────────────────────────────────────────────
    section("TEST 4: مرتجع شراء (من عميل)")
    if CUST_BUY_INV_ID:
        from models import InvoiceItem
        orig_items4 = InvoiceItem.query.filter_by(invoice_id=CUST_BUY_INV_ID).all()
        orig_item_id4 = orig_items4[0].id if orig_items4 else None
        r4 = c.post('/api/invoices', json={
            "invoice_type": "مرتجع شراء",
            "customer_id": 1,
            "original_invoice_id": CUST_BUY_INV_ID,
            "gold_price": gp,
            "gold_type": "scrap",
            "items": [{"weight": buy_weight, "karat": "21", "unit_price": buy_price, "quantity": 1, "name": "ذهب E2E", "original_invoice_item_id": orig_item_id4}],
            "payments": [{"payment_method_id": 1, "amount": buy_total, "safe_box_id": 1}],
            "total": buy_total,
        })
        d4 = json.loads(r4.data)
        if r4.status_code in (200, 201):
            inv_id4 = d4.get("id")
            ok(f"Invoice created: ID={inv_id4}")
            je4 = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv_id4).first()
            if je4:
                check_je_balance(je4.id, "مرتجع شراء")
            else:
                fail("JE not found for cust-buy return")
        else:
            fail(f"مرتجع شراء failed: {r4.status_code} {json.dumps(d4, ensure_ascii=False)[:300]}")
    else:
        print("  ⏭  Skipped (no cust-buy invoice)")

    # ─── TEST 5: شراء (مورد) ────────────────────────────────────────────────
    section("TEST 5: شراء (مورد - لازوردي)")
    supp_weight = 10.0  # 10g 21k
    supp_gold_val = round(gp * supp_weight, 2)
    r5 = c.post('/api/invoices', json={
        "invoice_type": "شراء",
        "supplier_id": 1,
        "gold_price": gp,
        "gold_type": "new",
        "karat_lines": [{"karat": 21, "weight_grams": supp_weight, "gold_value_cash": supp_gold_val}],
        "gold_subtotal": supp_gold_val,
        "total": supp_gold_val,
    })
    d5 = json.loads(r5.data)
    if r5.status_code in (200, 201):
        inv_id5 = d5.get("id")
        ok(f"Invoice created: ID={inv_id5} total={supp_gold_val}")
        je5 = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv_id5).first()
        if je5:
            check_je_balance(je5.id, "شراء (مورد)")
        else:
            fail("JE not found for supplier purchase")
        SUPP_INV_ID = inv_id5
    else:
        fail(f"شراء (مورد) failed: {r5.status_code} {json.dumps(d5, ensure_ascii=False)[:400]}")
        SUPP_INV_ID = None

    # ─── TEST 6: مرتجع شراء (مورد) ──────────────────────────────────────────
    section("TEST 6: مرتجع شراء (مورد - لازوردي)")
    if SUPP_INV_ID:
        r6 = c.post('/api/invoices', json={
            "invoice_type": "مرتجع شراء (مورد)",
            "supplier_id": 1,
            "original_invoice_id": SUPP_INV_ID,
            "gold_price": gp,
            "gold_type": "new",
            "karat_lines": [{"karat": 21, "weight_grams": supp_weight, "gold_value_cash": supp_gold_val}],
            "gold_subtotal": supp_gold_val,
            "total": supp_gold_val,
        })
        d6 = json.loads(r6.data)
        if r6.status_code in (200, 201):
            inv_id6 = d6.get("id")
            ok(f"Invoice created: ID={inv_id6}")
            je6 = JournalEntry.query.filter_by(reference_type='invoice', reference_id=inv_id6).first()
            if je6:
                check_je_balance(je6.id, "مرتجع شراء (مورد)")
            else:
                fail("JE not found for supplier return")
        else:
            fail(f"مرتجع شراء (مورد) failed: {r6.status_code} {json.dumps(d6, ensure_ascii=False)[:400]}")
    else:
        print("  ⏭  Skipped (no supplier invoice)")

    # TEST 7 (COGS through _auto_consume_weight_closing) went with the old
    # engine (ADR-048 phase 3a): a sale's waiting riyals are derived from the books.

# ─── SUMMARY ────────────────────────────────────────────────────────────────
section("SUMMARY")
if not errors:
    print(f"  {PASS} All E2E checks passed!")
else:
    for e in errors:
        print(f"  {FAIL} {e}")
    print(f"\n  Total failures: {len(errors)}")
    sys.exit(1)
