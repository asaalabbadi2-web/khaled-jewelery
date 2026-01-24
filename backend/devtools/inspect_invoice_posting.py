"""Inspect invoice posting artifacts (journal entries + safe box ledger).

Usage examples:
  ./venv/bin/python devtools/inspect_invoice_posting.py --latest-barter-sale
  ./venv/bin/python devtools/inspect_invoice_posting.py --invoice-id 123

This script is read-only.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict
from typing import Any, Iterable

# Ensure the backend package root is importable when running from backend/devtools.
_BACKEND_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if _BACKEND_ROOT not in sys.path:
    sys.path.insert(0, _BACKEND_ROOT)

from app import app
from models import Invoice, InvoiceWeightSettlement, JournalEntry, SafeBox, SafeBoxTransaction


def _fm(x: Any) -> float:
    try:
        return round(float(x or 0.0), 2)
    except Exception:
        return 0.0


def _fw(x: Any) -> float:
    try:
        return round(float(x or 0.0), 4)
    except Exception:
        return 0.0


def _print_kv(title: str, items: dict[str, Any]) -> None:
    print(title)
    for k, v in items.items():
        print(f"  {k}: {v}")


def _iter_safe_box_transactions(invoice_id: int, payment_ids: list[int]) -> list[SafeBoxTransaction]:
    # SQLite and PostgreSQL will both handle this IN.
    base_q = SafeBoxTransaction.query.filter(SafeBoxTransaction.invoice_id == invoice_id)
    tx = list(base_q.order_by(SafeBoxTransaction.id.asc()).all())

    if payment_ids:
        tx2 = list(
            SafeBoxTransaction.query.filter(SafeBoxTransaction.invoice_payment_id.in_(payment_ids))
            .order_by(SafeBoxTransaction.id.asc())
            .all()
        )
        seen = {t.id for t in tx}
        for t in tx2:
            if t.id not in seen:
                tx.append(t)
                seen.add(t.id)

    tx.sort(key=lambda t: t.id)
    return tx


def _print_journal_entries(invoice_id: int) -> None:
    jes = list(
        JournalEntry.query.filter(JournalEntry.reference_type == "invoice")
        .filter(JournalEntry.reference_id == invoice_id)
        .order_by(JournalEntry.id.asc())
        .all()
    )

    print(f"\nJOURNAL_ENTRIES ({len(jes)})")
    for je in jes:
        print(f"  JE {je.id} {je.entry_number} posted={bool(je.is_posted)} date={je.date}")
        print(f"    desc: {je.description}")

        totals = defaultdict(float)
        for ln in je.lines:
            if getattr(ln, "is_deleted", False):
                continue

            acc = getattr(ln, "account", None)
            acc_num = getattr(acc, "account_number", None)
            acc_name = getattr(acc, "name", None)

            cash_d = _fm(getattr(ln, "cash_debit", 0.0))
            cash_c = _fm(getattr(ln, "cash_credit", 0.0))

            # Gold weights by karat
            w18d = _fw(getattr(ln, "debit_18k", 0.0))
            w18c = _fw(getattr(ln, "credit_18k", 0.0))
            w21d = _fw(getattr(ln, "debit_21k", 0.0))
            w21c = _fw(getattr(ln, "credit_21k", 0.0))
            w22d = _fw(getattr(ln, "debit_22k", 0.0))
            w22c = _fw(getattr(ln, "credit_22k", 0.0))
            w24d = _fw(getattr(ln, "debit_24k", 0.0))
            w24c = _fw(getattr(ln, "credit_24k", 0.0))

            dw = _fw(getattr(ln, "debit_weight", 0.0))
            cw = _fw(getattr(ln, "credit_weight", 0.0))

            totals["cash_d"] += cash_d
            totals["cash_c"] += cash_c
            totals["w18d"] += w18d
            totals["w18c"] += w18c
            totals["w21d"] += w21d
            totals["w21c"] += w21c
            totals["w22d"] += w22d
            totals["w22c"] += w22c
            totals["w24d"] += w24d
            totals["w24c"] += w24c
            totals["dw"] += dw
            totals["cw"] += cw

            if any([cash_d, cash_c, w18d, w18c, w21d, w21c, w22d, w22c, w24d, w24c, dw, cw]):
                desc = (getattr(ln, "description", None) or "")
                print(
                    f"    - {acc_num} {acc_name} | cash D/C {cash_d}/{cash_c} "
                    f"| 18 D/C {w18d}/{w18c} | 21 D/C {w21d}/{w21c} | 22 D/C {w22d}/{w22c} | 24 D/C {w24d}/{w24c} "
                    f"| w D/C {dw}/{cw} | {desc[:90]}"
                )

        print(
            "    TOTALS "
            + str(
                {
                    "cash_debit": _fm(totals["cash_d"]),
                    "cash_credit": _fm(totals["cash_c"]),
                    "21k_debit": _fw(totals["w21d"]),
                    "21k_credit": _fw(totals["w21c"]),
                    "weight_debit": _fw(totals["dw"]),
                    "weight_credit": _fw(totals["cw"]),
                }
            )
        )


def _print_safe_box_transactions(invoice: Invoice) -> None:
    pays = list(getattr(invoice, "payments", []) or [])
    payment_ids = [p.id for p in pays]

    tx = _iter_safe_box_transactions(invoice.id, payment_ids)
    print(f"\nSAFE_BOX_TRANSACTIONS ({len(tx)})")

    for t in tx:
        sb = SafeBox.query.get(t.safe_box_id)
        sb_name = getattr(sb, "name", None)
        sb_type = getattr(sb, "safe_type", None)

        print(
            "  - "
            + str(
                {
                    "id": t.id,
                    "safe_box_id": t.safe_box_id,
                    "safe_box_name": sb_name,
                    "safe_box_type": sb_type,
                    "direction": t.direction,
                    "amount_cash": _fm(t.amount_cash),
                    "weight_18k": _fw(t.weight_18k),
                    "weight_21k": _fw(t.weight_21k),
                    "weight_22k": _fw(t.weight_22k),
                    "weight_24k": _fw(t.weight_24k),
                    "ref_type": t.ref_type,
                    "ref_id": t.ref_id,
                    "invoice_id": t.invoice_id,
                    "invoice_payment_id": t.invoice_payment_id,
                    "notes": (t.notes or "")[:120],
                }
            )
        )


def _print_weight_settlements(invoice_id: int) -> None:
    ws = list(
        InvoiceWeightSettlement.query.filter(InvoiceWeightSettlement.invoice_id == invoice_id)
        .order_by(InvoiceWeightSettlement.id.asc())
        .all()
    )
    print(f"\nWEIGHT_SETTLEMENTS ({len(ws)})")
    for s in ws:
        print(
            "  - "
            + str(
                {
                    "id": s.id,
                    "transaction_type": s.transaction_type,
                    "gold_weight": _fw(s.gold_weight),
                    "original_karat": s.original_karat,
                    "original_weight": _fw(s.original_weight),
                    "cash_amount": _fm(s.cash_amount),
                    "journal_entry_id": s.journal_entry_id,
                    "notes": (s.notes or "")[:120],
                }
            )
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    g = parser.add_mutually_exclusive_group(required=True)
    g.add_argument("--invoice-id", type=int)
    g.add_argument("--latest-barter-sale", action="store_true")

    args = parser.parse_args()

    with app.app_context():
        if args.invoice_id:
            inv = Invoice.query.get(args.invoice_id)
        else:
            inv = (
                Invoice.query.filter(Invoice.invoice_type == "بيع")
                .filter(Invoice.barter_total > 0.01)
                .order_by(Invoice.id.desc())
                .first()
            )

        if not inv:
            print("Invoice not found")
            return 2

        _print_kv(
            "INVOICE",
            {
                "id": inv.id,
                "invoice_type": inv.invoice_type,
                "invoice_type_id": inv.invoice_type_id,
                "date": inv.date,
                "total": _fm(inv.total),
                "amount_paid": _fm(inv.amount_paid),
                "barter_total": _fm(getattr(inv, "barter_total", 0.0)),
                "total_settled_amount": _fm(_fm(inv.amount_paid) + _fm(getattr(inv, "barter_total", 0.0))),
                "status": inv.status,
                "is_posted": bool(inv.is_posted),
                "posted_at": inv.posted_at,
                "posted_by": inv.posted_by,
                "customer_id": inv.customer_id,
                "employee_id": inv.employee_id,
                "gold_type": inv.gold_type,
                "safe_box_id": inv.safe_box_id,
            },
        )

        pays = list(getattr(inv, "payments", []) or [])
        print(f"\nINVOICE_PAYMENTS ({len(pays)})")
        for p in pays:
            pm = getattr(p, "payment_method", None)
            print(
                "  - "
                + str(
                    {
                        "id": p.id,
                        "payment_method_id": p.payment_method_id,
                        "payment_method_name": getattr(pm, "name", None),
                        "payment_type": getattr(pm, "payment_type", None),
                        "amount": _fm(p.amount),
                        "net_amount": _fm(p.net_amount),
                        "commission_amount": _fm(p.commission_amount),
                        "commission_vat": _fm(p.commission_vat),
                    }
                )
            )

        _print_safe_box_transactions(inv)
        _print_journal_entries(inv.id)
        _print_weight_settlements(inv.id)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
