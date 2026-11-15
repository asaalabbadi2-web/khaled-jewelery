"""What the shop will pay soon, for the manager's dashboard (the owner, 15 Nov 2026).

«اقترح ما ينقصها» -- «طبق جميع ما اقترحت»: the liquidity said what the shop
holds, and nothing said what is about to leave it. Each by its own reader,
never a sum of this module's:

  period_expenses  each active period expense still to be paid: what is left
                   of its amount (services/period_expense.values), what of it
                   is owed now (its months accrued and unpaid), and its end
  salaries         what the employees' salary payables hold for them
                   (services/payroll_payment.owed_salary's account, its credit)
  suppliers        what we owe the suppliers, riyals and grams -- the
                   positions' own figures (services/dashboard_positions)
  vat              what the filed returns left owed to the authority
                   (services/dashboard_vat's `owed`, when above zero)
  total_cash       their riyals together; the suppliers' grams apart

Nothing here writes.
"""
from __future__ import annotations

from datetime import date


def _salaries() -> dict:
    from models import EmployeeAccount
    from services.employee_termination import _credit
    owed = [_credit(row.account_id) for row in EmployeeAccount.query.filter_by(role='salary_payable')]
    owed = [v for v in owed if v > 0.005]
    return {'amount': round(sum(owed), 2), 'count': len(owed)}


def _period_expenses(today: date) -> list:
    from models import PeriodExpense
    from services.period_expense import values
    out = []
    for pe in PeriodExpense.query.filter_by(status='active').order_by(PeriodExpense.period_end):
        v = values(pe, today)
        if v['remaining_to_pay'] <= 0.005:
            continue
        out.append({'id': pe.id, 'name': pe.description, 'to_pay': v['remaining_to_pay'],
                    'owed_now': round(max(-v['balance'], 0.0), 2), 'by': pe.period_end.isoformat()})
    return out


def upcoming(today: date, *, suppliers: dict | None, vat_owed: float | None) -> dict:
    """*suppliers*: the positions' suppliers (null when they could not be read);
    *vat_owed*: the VAT card's `owed` (null likewise)."""
    expenses = _period_expenses(today)
    salaries = _salaries()
    supplier_cash = None if suppliers is None else round(float(suppliers.get('we_owe_cash') or 0.0), 2)
    supplier_gold = None if suppliers is None else round(float(suppliers.get('we_owe_gold') or 0.0), 3)
    vat = None if vat_owed is None else round(max(float(vat_owed), 0.0), 2)
    parts = [sum(e['to_pay'] for e in expenses), salaries['amount'], supplier_cash, vat]
    return {
        'period_expenses': expenses,
        'salaries': salaries,
        'suppliers': {'cash': supplier_cash, 'gold': supplier_gold,
                      'count': None if suppliers is None else int(suppliers.get('we_owe_count') or 0)},
        'vat': vat,
        # a part not read leaves the whole not read: never a total that is short
        'total_cash': None if any(p is None for p in parts) else round(sum(parts), 2),
    }
