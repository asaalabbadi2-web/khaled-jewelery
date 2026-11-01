"""An employee's leaves, their balance, and their mark on his run (EMP-4, ش4).

The owner, 1 Nov 2026 («الإجازات: لِمَ لا، اقتراحك؟» -- «اودع وابدأ»). No leave
was kept. The proposal he took:

  1. a kind of leave is paid or not, accruing or not, its days the owner's --
     none seeded; unset, no balance is held to;
  2. an accruing kind (annual) earns its days a year from the hire date, by
     the day, the longer days after some years (art. 109's 21 and 30 after 5,
     entered by him); one that does not (sick) has its days a calendar year;
  3. a leave runs from a day to a day, its days the calendar's; it does not
     overlap another of his; the manager records it, approved -- or approves a
     request; not beyond the balance where one is held;
  4. an unpaid leave lessens his run's days (services/payroll_run); it is not
     recorded nor cancelled in a month whose run is approved.
tests/test_employee_leave.py.
"""
from __future__ import annotations

from datetime import date

from models import Employee, EmployeeLeave, LeaveType, Payroll, PayrollRun, db
from services.payroll_laws import PayrollRefused

STANDING = ('requested', 'approved')


def _days(start: date, end: date) -> int:
    return (end - start).days + 1


def _overlap(start: date, end: date, first: date, last: date) -> int:
    low, high = max(start, first), min(end, last)
    return _days(low, high) if low <= high else 0


def _day(value, label: str) -> date:
    try:
        return date.fromisoformat(str(value))
    except (TypeError, ValueError):
        raise PayrollRefused(f'{label}: تاريخ YYYY-MM-DD') from None


# ── kinds ──────────────────────────────────────────────────────────────────────

def save_type(data: dict, kind=None) -> LeaveType:
    """Its days the owner's; an empty one unset, not zero. Caller commits."""
    name = str(data.get('name', kind.name if kind else '') or '').strip()
    if not name:
        raise PayrollRefused('اسم نوع الإجازة مطلوب')
    clash = LeaveType.query.filter_by(name=name).first()
    if clash is not None and clash is not kind:
        raise PayrollRefused('يوجد نوع إجازة بهذا الاسم')
    if kind is None:
        kind = LeaveType(is_active=True)
        db.session.add(kind)
    kind.name = name
    for flag in ('paid', 'accrues', 'is_active'):
        if flag in data:
            setattr(kind, flag, bool(data[flag]))
    for field, whole in (('days_per_year', False), ('longer_after_years', True), ('longer_days_per_year', False)):
        if field in data:
            value = data.get(field)
            if value in (None, ''):
                setattr(kind, field, None)
                continue
            try:
                number = int(value) if whole else round(float(value), 2)
            except (TypeError, ValueError):
                raise PayrollRefused(f'{field}: رقم') from None
            if number < 0:
                raise PayrollRefused(f'{field}: لا يكون سالبًا')
            setattr(kind, field, number)
    db.session.flush()
    return kind


# ── balance ────────────────────────────────────────────────────────────────────

def entitlement(employee, kind, day: date):
    """What he has earned of the kind by the day -- None when not held to."""
    if kind.days_per_year is None:
        return None
    if not kind.accrues:
        return float(kind.days_per_year)
    if employee.hire_date is None:
        return None
    from services.payroll_eos import service_years
    years = service_years(employee.hire_date, day)
    after, longer = kind.longer_after_years, kind.longer_days_per_year
    if after is not None and longer is not None:
        earned = min(years, after) * kind.days_per_year + max(years - after, 0) * longer
    else:
        earned = years * kind.days_per_year
    return round(earned, 2)


def taken(employee, kind, day: date, *, exclude=None) -> int:
    """The approved days of the kind: all of them for an accruing one, the
    calendar year's for one that is not."""
    first, last = (date.min, date.max) if kind.accrues else (date(day.year, 1, 1), date(day.year, 12, 31))
    total = 0
    for leave in EmployeeLeave.query.filter_by(employee_id=employee.id, type_id=kind.id, status='approved'):
        if exclude is not None and leave.id == exclude.id:
            continue
        total += _overlap(leave.start_date, leave.end_date, first, last)
    return total


def balance(employee, kind, day: date):
    earned = entitlement(employee, kind, day)
    return None if earned is None else round(earned - taken(employee, kind, day), 2)


def balances(employee, day: date) -> list[dict]:
    rows = []
    for kind in LeaveType.query.filter_by(is_active=True).order_by(LeaveType.id):
        earned = entitlement(employee, kind, day)
        used = taken(employee, kind, day)
        rows.append({'type_id': kind.id, 'type': kind.name, 'paid': kind.paid, 'entitlement': earned,
                     'taken': used, 'balance': None if earned is None else round(earned - used, 2),
                     'reason': None if earned is not None else
                     ('no_hire_date' if kind.accrues and kind.days_per_year is not None else 'not_set')})
    return rows


# ── a leave ────────────────────────────────────────────────────────────────────

def _refuse_in_an_approved_run(employee_id: int, start: date, end: date) -> None:
    """Law 4: an unpaid leave's days are a run's -- not in a month already approved."""
    month, last_month = (start.year, start.month), (end.year, end.month)
    for line in (Payroll.query.join(PayrollRun, Payroll.payroll_run_id == PayrollRun.id)
                 .filter(Payroll.employee_id == employee_id, PayrollRun.status.in_(('approved', 'paid')))):
        if month <= (line.year, line.month) <= last_month:
            raise PayrollRefused(f'مسير {line.month}/{line.year} معتمد: الإجازة بدون أجر فيه تُسجَّل بإلغائه '
                                 'وإعادة إنشائه، أو تُخصم غيابًا من مسير لاحق.')


def _refuse_beyond(employee, kind, leave) -> None:
    left = entitlement(employee, kind, leave.end_date)
    if left is None:
        return
    left = round(left - taken(employee, kind, leave.end_date, exclude=leave), 2)
    if leave.days > left:
        raise PayrollRefused(f'رصيد {kind.name} {left:,.2f} يوم، والإجازة {leave.days}: '
                             'تُسجَّل بأقل منها، أو الباقي بنوع آخر (بدون أجر).')


def record(employee_id: int, data: dict, *, by: str, now) -> EmployeeLeave:
    """Law 3: recorded by the manager, approved -- or a request. Caller commits."""
    employee = db.session.get(Employee, employee_id)
    if employee is None:
        raise PayrollRefused('الموظف غير موجود')
    kind = db.session.get(LeaveType, int(data['type_id'])) if data.get('type_id') else None
    if kind is None or not kind.is_active:
        raise PayrollRefused('نوع الإجازة غير موجود')
    start, end = _day(data.get('start_date'), 'من'), _day(data.get('end_date'), 'إلى')
    if end < start:
        raise PayrollRefused('نهاية الإجازة قبل بدايتها')
    for other in EmployeeLeave.query.filter(EmployeeLeave.employee_id == employee_id,
                                            EmployeeLeave.status.in_(STANDING)):
        if _overlap(start, end, other.start_date, other.end_date):
            raise PayrollRefused(f'تتداخل مع إجازة {other.type.name} من {other.start_date} إلى {other.end_date}')
    status = 'requested' if data.get('status') == 'requested' else 'approved'
    leave = EmployeeLeave(employee_id=employee_id, type_id=kind.id, start_date=start, end_date=end,
                          days=_days(start, end), status=status, notes=data.get('notes'), created_by=by)
    if status == 'approved':
        _approved(employee, kind, leave, by=by, now=now)
    db.session.add(leave)
    db.session.flush()
    return leave


def _approved(employee, kind, leave, *, by: str, now) -> None:
    _refuse_beyond(employee, kind, leave)
    if not kind.paid:
        _refuse_in_an_approved_run(employee.id, leave.start_date, leave.end_date)
    leave.status, leave.decided_by, leave.decided_at = 'approved', by, now


def approve(leave, *, by: str, now) -> None:
    if leave.status != 'requested':
        raise PayrollRefused('يُعتمد طلب الإجازة وحده')
    _approved(leave.employee, leave.type, leave, by=by, now=now)


def reject(leave, *, by: str, now) -> None:
    if leave.status != 'requested':
        raise PayrollRefused('يُرفض طلب الإجازة وحده')
    leave.status, leave.decided_by, leave.decided_at = 'rejected', by, now


def cancel(leave, *, by: str, now) -> None:
    if leave.status not in STANDING:
        raise PayrollRefused('الإجازة ليست قائمة')
    if leave.status == 'approved' and not leave.type.paid:
        _refuse_in_an_approved_run(leave.employee_id, leave.start_date, leave.end_date)
    leave.status, leave.decided_by, leave.decided_at = 'cancelled', by, now


def unpaid_days(employee_id: int, first: date, last: date) -> int:
    """Law 4: his approved unpaid leave's days within the period."""
    total = 0
    for leave in (EmployeeLeave.query.join(LeaveType, EmployeeLeave.type_id == LeaveType.id)
                  .filter(EmployeeLeave.employee_id == employee_id, EmployeeLeave.status == 'approved',
                          LeaveType.paid.is_(False))):
        total += _overlap(leave.start_date, leave.end_date, first, last)
    return total
