"""An advance repaid from the salary by a plan of installments (PAYROLL-3, M3).

The owner, 1 Nov 2026 («السلف: ليس هناك قاعدة محددة، أريد اقتراحك»; «صالح
العبادي: نعم سلف»). The books hold the advance -- the employee's advance
account (employee.account_id), 104,000 over five on the 31 Oct copy -- and a
plan says how it is repaid:

  1. a plan's amount is the account's balance not yet planned, never more;
  2. its installment is the amount over the policy's installments unless said,
     capped by the policy's share of the wage (Labour Law art. 92) -- above it
     only with the employee's consent, noted;
  3. the run takes each month's installment, no more than is left, and the
     installments of a month together within the cap (consent apart);
  4. what is left is the amount less the installments of the approved runs --
     a cancelled run gives its installments back.

The installment is credited to the advance account in the run's accrual
(services/payroll_run). tests/test_payroll_advances_and_contributions.py.
"""
from __future__ import annotations

import calendar
import json
from datetime import date

from models import EmployeeAdvancePlan, Employee, Payroll, PayrollRun, db
from services.payroll_laws import PayrollRefused, refuse_bad_period
from services.payroll_policy import require, structure_on

ADVANCE = 'advance'


def _rounded(value, label: str) -> float:
    try:
        number = round(float(value), 2)
    except (TypeError, ValueError):
        raise PayrollRefused(f'{label}: رقم') from None
    if number <= 0:
        raise PayrollRefused(f'{label}: موجب')
    return number


def gold_balance(employee) -> dict:
    """What gold he owes on his advance account, by karat, from the books --
    the weight its parallel (memo) account holds (the owner, 2 Nov 2026:
    «السلف الوزنية لم تُعتمد»: 18.64 g 21k for صالح on the 2 Nov copy)."""
    from models import Account
    from services.live_balances import live_balances_by_account_ids
    account = db.session.get(Account, employee.account_id) if employee.account_id else None
    memo_id = getattr(account, 'memo_account_id', None) if account is not None else None
    if not memo_id:
        return {}
    balance = live_balances_by_account_ids([memo_id]).get(memo_id, {})
    return {karat: round(grams, 3) for karat, grams in balance.items() if karat != 'cash' and round(grams, 3)}


def account_balance(employee) -> float:
    """What the employee owes on his advance account, from the books."""
    from services.live_balances import live_balances_by_account_ids
    if not employee.account_id:
        return 0.0
    return round(live_balances_by_account_ids([employee.account_id]).get(employee.account_id, {})
                 .get('cash', 0.0), 2)


def taken(plan, *, exclude_run_id=None) -> float:
    """The installments of the plan taken by the approved (or paid) runs."""
    query = (Payroll.query.join(PayrollRun, Payroll.payroll_run_id == PayrollRun.id)
             .filter(Payroll.employee_id == plan.employee_id,
                     PayrollRun.status.in_(('approved', 'paid'))))
    if exclude_run_id is not None:
        query = query.filter(PayrollRun.id != exclude_run_id)
    total = 0.0
    for line in query:
        for row in (json.loads(line.breakdown or '{}').get('deductions') or []):
            if row.get('kind') == ADVANCE and row.get('plan_id') == plan.id:
                total += float(row['amount'])
    return round(total, 2)


def remaining(plan) -> float:
    return round(plan.amount - taken(plan), 2)


def cap_of(gross: float) -> float:
    return round(gross * float(require('advance_cap_ratio')), 2)


def create_plan(employee_id: int, data: dict, *, by: str, today: date) -> EmployeeAdvancePlan:
    """Law 1 and 2. Caller commits."""
    employee = db.session.get(Employee, employee_id)
    if employee is None:
        raise PayrollRefused('الموظف غير موجود')
    if not employee.account_id:
        raise PayrollRefused('للموظف حساب سلف غير مربوط: يُربط من شاشة الموظفين')
    amount = _rounded(data.get('amount'), 'مبلغ السلفة')
    planned = sum(remaining(p) for p in employee.advance_plans.filter_by(status='active'))
    free = round(account_balance(employee) - planned, 2)
    if amount > free:
        raise PayrollRefused(f'رصيد سلف الموظف غير المجدول {free:,.2f}: لا تُجدول سلفة أكبر منه. '
                             'تُصرف السلفة بسندها أولًا، ثم تُجدول.')
    if data.get('installment') not in (None, ''):
        installment = _rounded(data.get('installment'), 'القسط')
    else:
        installment = round(amount / int(require('advance_installments')), 2)
    month = int(data.get('start_month') or today.month)
    year = int(data.get('start_year') or today.year)
    refuse_bad_period(month, year)
    consent = bool(data.get('consent'))
    structure = structure_on(employee.id, date(year, month, calendar.monthrange(year, month)[1]))
    if structure is None:
        raise PayrollRefused('لا هيكل راتب للموظف في شهر بدء الأقساط: لا يُعرف حدّ القسط من أجره')
    cap = cap_of(structure.gross)
    if installment > cap and not consent:
        raise PayrollRefused(f'القسط يزيد على {cap:,.2f} (حدّ الخصم من الأجر، المادة 92). '
                             'يُقبل بموافقة الموظف المكتوبة: أشر إليها واذكرها.', 'advance_cap_exceeded')
    if consent and not str(data.get('consent_note') or '').strip():
        raise PayrollRefused('اذكر موافقة الموظف (تاريخها أو مرجعها)')
    plan = EmployeeAdvancePlan(employee_id=employee.id, amount=amount, installment=min(installment, amount),
                               start_month=month, start_year=year, consent=consent,
                               consent_note=data.get('consent_note'), notes=data.get('notes'),
                               status='active', created_by=by)
    db.session.add(plan)
    db.session.flush()
    return plan


def cancel_plan(plan) -> None:
    """Its taken installments stay; nothing more is taken. Caller commits."""
    plan.status = 'cancelled'


def to_dict(plan) -> dict:
    left = remaining(plan)
    return {'id': plan.id, 'employee_id': plan.employee_id, 'amount': plan.amount,
            'installment': plan.installment, 'start_month': plan.start_month, 'start_year': plan.start_year,
            'consent': plan.consent, 'consent_note': plan.consent_note, 'notes': plan.notes,
            'status': 'settled' if plan.status == 'active' and left <= 0 else plan.status,
            'taken': round(plan.amount - left, 2), 'remaining': left}


def installments_for(employee, month: int, year: int, gross: float) -> list[dict]:
    """Law 3: the month's installments -- each no more than is left, those
    without consent together within the cap."""
    rows, room = [], cap_of(gross)
    plans = (employee.advance_plans.filter_by(status='active')
             .order_by(EmployeeAdvancePlan.id).all())
    for plan in plans:
        if (plan.start_year, plan.start_month) > (year, month):
            continue
        amount = min(plan.installment, remaining(plan))
        if not plan.consent:
            amount = min(amount, room)
            room = round(room - amount, 2)
        amount = round(amount, 2)
        if amount > 0:
            rows.append({'kind': ADVANCE, 'plan_id': plan.id, 'label': 'قسط سلفة', 'amount': amount})
    return rows


def refuse_overtaken(run) -> None:
    """At approval: a plan is not taken beyond its amount by two drafts."""
    for line in run.entries:
        for row in (json.loads(line.breakdown or '{}').get('deductions') or []):
            if row.get('kind') != ADVANCE:
                continue
            plan = db.session.get(EmployeeAdvancePlan, row['plan_id'])
            left = round(plan.amount - taken(plan, exclude_run_id=run.id), 2)
            if row['amount'] > left:
                raise PayrollRefused(f'قسط سلفة {line.employee.name} يزيد على الباقي منها ({left:,.2f}): '
                                     'اعتُمد مسير آخر أخذ منها. ألغِ المسودة وأنشئها من جديد.')
