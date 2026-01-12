#!/usr/bin/env python3
"""Local verification for the 'exclude_from_ledger' fix.

Creates:
- a test supplier
- a 'شراء' invoice

Then inspects:
- generated JournalEntryLine rows for supplier tagging
- supplier statement endpoint output

This is a DEV helper script. It does not modify code; it writes to the configured database.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import sys
import urllib.error
import urllib.request


def _http_json(method: str, url: str, body: dict | None = None) -> dict:
    data = None
    headers = {"Content-Type": "application/json"}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")

    req = urllib.request.Request(url, data=data, method=method.upper(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {"error": raw}
        raise RuntimeError(f"HTTP {e.code} for {method} {url}: {payload}") from e


def main() -> int:
    base = os.getenv("BASE_URL", "http://localhost:8001/api").rstrip("/")

    now = _dt.datetime.now().replace(microsecond=0)

    supplier = _http_json("POST", f"{base}/suppliers", {"name": "TEST SUPPLIER LEDGER"})
    supplier_id = int(supplier["id"])

    # Baseline statement (should usually be empty for a brand new supplier)
    stmt_before = _http_json("GET", f"{base}/suppliers/{supplier_id}/statement")
    before_lines_out = stmt_before.get("lines") or stmt_before.get("statement_lines") or []

    invoice_body = {
        "invoice_type": "شراء",
        "supplier_id": supplier_id,
        "date": now.isoformat(),
        "total": 5345.0,
        "gold_subtotal": 5000.0,
        "wage_subtotal": 300.0,
        "manufacturing_wage_cash": 300.0,
        "apply_gold_tax": False,
        "gold_tax_total": 0.0,
        "wage_tax_total": 45.0,
        "total_tax": 45.0,
        "total_weight": 10.0,
        "karat_lines": [
            {
                "karat": 21,
                "weight_grams": 10.0,
                "gold_value_cash": 5000.0,
                "manufacturing_wage_cash": 300.0,
            }
        ],
        "items": [],
    }

    inv = _http_json("POST", f"{base}/invoices", invoice_body)
    if "error" in inv:
        raise RuntimeError(f"Invoice creation failed: {inv}")

    invoice_id = int(inv["id"])

    # Supplier ledger is the best API-level indicator of whether lines were tagged with supplier_id.
    ledger_after = _http_json("GET", f"{base}/suppliers/{supplier_id}/ledger?per_page=200")
    movements = ledger_after.get("movements") or []

    print("=== VERIFY SUPPLIER PURCHASE LEDGER ===")
    print(f"base_url: {base}")
    print(f"supplier_id: {supplier_id}")
    print(f"statement_lines_before_invoice: {len(before_lines_out)}")
    print(f"invoice_id:  {invoice_id}")
    print(
        "invoice_api: "
        f"type={inv.get('invoice_type')} supplier_id={inv.get('supplier_id')} "
        f"total={inv.get('total')} total_tax={inv.get('total_tax')}"
    )
    print("---")
    print(f"ledger_movements_tagged: {len(movements)}")

    suspicious = []
    print("--- supplier ledger movements (first 20) ---")
    for m in movements[:20]:
        desc = str(m.get('description') or '').strip()
        acc_name = str(m.get('account_name') or '')
        cash_cr = m.get('cash_credit')
        g21_cr = m.get('gold_21k_credit')
        print(f"- je={m.get('journal_entry_id')} acc={acc_name} cash_cr={cash_cr} g21_cr={g21_cr} desc={desc[:60]}")
        # Flag supplier-tagged movements that look like inventory/bridge/VAT lines.
        # Note: payable descriptions can legitimately include the word "ضريبة" (e.g. wage VAT).
        desc_lower = desc
        is_supplier_payable_desc = "التزام المورد" in desc_lower
        desc_suspicious = any(k in desc_lower for k in ("مخزون", "جسر", "تقييم", "VAT"))
        acc_suspicious = any(k in acc_name for k in ("مخزون", "جسر", "ضريبة"))
        if (desc_suspicious and not is_supplier_payable_desc) or acc_suspicious:
            suspicious.append(desc or acc_name)

    # Supplier statement validation (high-level)
    stmt = _http_json("GET", f"{base}/suppliers/{supplier_id}/statement")
    lines_out = stmt.get("lines") or stmt.get("statement_lines") or []
    print("--- supplier statement ---")
    print(f"statement_lines: {len(lines_out)}")

    # Try to locate the two intended lines by description.
    descs = [str(l.get("description") or l.get("desc") or "") for l in lines_out if isinstance(l, dict)]
    has_weight_payable = any("التزام المورد" in d and "ذهب" in d for d in descs)
    has_wage_payable = any("التزام المورد" in d and "أجور" in d for d in descs)
    print(f"has_weight_payable_line: {bool(has_weight_payable)}")
    print(f"has_wage_payable_line:   {bool(has_wage_payable)}")

    try:
        cb_cash = float(stmt.get('closing_balance_cash') or 0.0)
        cb_gold = float(stmt.get('closing_balance_gold_normalized') or 0.0)
        print(f"closing_balance_cash: {round(cb_cash,2)}")
        print(f"closing_balance_gold_normalized: {round(cb_gold,3)}")
    except Exception:
        cb_cash = None
        cb_gold = None

    ok = True
    # We expect ledger to show only the two payable lines for this minimal test.
    if len(movements) == 0:
        ok = False
        print("!!! FAIL: supplier ledger returned 0 tagged movements")
    if len(movements) > 2:
        ok = False
        print("!!! FAIL: supplier ledger has >2 tagged movements (potential over-tagging)")
    if suspicious:
        ok = False
        print("!!! FAIL: suspicious movements tagged to supplier (inventory/bridge/tax)")

    # The statement uses journal_entry.description, so descriptions may not match exactly.
    # We still expect the balances to reflect the two payables: cash -345 and gold -10 (main karat).
    if cb_cash is not None and abs(cb_cash - (-345.0)) > 0.05:
        ok = False
        print("!!! FAIL: closing cash balance not ~ -345.00")
    if cb_gold is not None and abs(cb_gold - (-10.0)) > 0.01:
        ok = False
        print("!!! FAIL: closing gold balance not ~ -10.000")

    print("---")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("ERROR:", exc)
        raise
