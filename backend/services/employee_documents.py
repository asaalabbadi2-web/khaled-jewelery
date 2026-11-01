"""An employee's contract and documents, and what of them nears its end (EMP-3, ش3).

The owner, 1 Nov 2026: the documents followed «ما يُعمل به في الأنظمة المماثلة،
وإن كان ممكنًا أن يكون ضبط الأيام اختياريًا». On the 1 Nov copy nothing of an
employee's contract or documents was kept.

  - a contract is fixed-term (its end after its start) or not (no end); its
    probation ends within 180 days of its start (Labour Law art. 53: 90,
    extended by written agreement to 180 at the most); a renewal is a new
    contract, the one in force the latest begun;
  - a document is of a kind the owner keeps (seeded the common six), its end
    not before its issue; a renewal is a new row, the latest of a kind the one
    followed;
  - what nears its end, of the active employees: a document within its kind's
    alert days, a contract's end or its probation's within the policy's
    contract_alert_days -- days the owner sets; unset, nothing is said.
The manager's dashboard says them (services/dashboard_alerts); the file lists
them (services/employee_file). tests/test_employee_contracts_documents.py.
"""
from __future__ import annotations

from datetime import date, timedelta

from models import Employee, EmployeeContract, EmployeeDocument, EmployeeDocumentType, db
from services.payroll_laws import PayrollRefused

KINDS = ('fixed', 'indefinite')
PROBATION_MAX_DAYS = 180          # art. 53: 90 days, extended by written agreement to 180 at the most


def _day(value, label: str, *, required: bool = False):
    if value in (None, ''):
        if required:
            raise PayrollRefused(f'{label} مطلوب (YYYY-MM-DD)')
        return None
    try:
        return date.fromisoformat(str(value))
    except ValueError:
        raise PayrollRefused(f'{label}: تاريخ YYYY-MM-DD') from None


# ── contracts ──────────────────────────────────────────────────────────────────

def save_contract(employee_id: int, data: dict, *, by: str, contract=None) -> EmployeeContract:
    """Caller commits."""
    if db.session.get(Employee, employee_id) is None:
        raise PayrollRefused('الموظف غير موجود')
    kind = data.get('kind', contract.kind if contract else None)
    if kind not in KINDS:
        raise PayrollRefused('نوع العقد: محدد المدة أو غير محدد المدة')
    start = _day(data.get('start_date', contract.start_date.isoformat() if contract else None), 'بداية العقد',
                 required=True)
    end = _day(data.get('end_date', contract.end_date.isoformat() if contract and contract.end_date else None),
               'نهاية العقد')
    probation = _day(data.get('probation_end', contract.probation_end.isoformat()
                              if contract and contract.probation_end else None), 'نهاية التجربة')
    if kind == 'fixed' and (end is None or end <= start):
        raise PayrollRefused('العقد محدد المدة نهايته بعد بدايته')
    if kind == 'indefinite' and end is not None:
        raise PayrollRefused('العقد غير محدد المدة بلا نهاية')
    if probation is not None and not (start <= probation <= start + timedelta(days=PROBATION_MAX_DAYS)):
        raise PayrollRefused('فترة التجربة لا تتجاوز 180 يومًا من بداية العقد (المادة 53)')
    clash = EmployeeContract.query.filter_by(employee_id=employee_id, start_date=start).first()
    if clash is not None and clash is not contract:
        raise PayrollRefused('للموظف عقد يبدأ في هذا اليوم')
    if contract is None:
        contract = EmployeeContract(employee_id=employee_id, created_by=by)
        db.session.add(contract)
    contract.kind, contract.start_date, contract.end_date, contract.probation_end = kind, start, end, probation
    if 'notes' in data:
        contract.notes = data.get('notes')
    db.session.flush()
    return contract


def contract_on(employee_id: int, day: date):
    return (EmployeeContract.query.filter(EmployeeContract.employee_id == employee_id,
                                          EmployeeContract.start_date <= day)
            .order_by(EmployeeContract.start_date.desc()).first())


# ── documents ──────────────────────────────────────────────────────────────────

def save_type(data: dict, kind=None) -> EmployeeDocumentType:
    """A kind of document, its alert days the owner's (empty = no alert). Caller commits."""
    name = str(data.get('name', kind.name if kind else '') or '').strip()
    if not name:
        raise PayrollRefused('اسم نوع الوثيقة مطلوب')
    clash = EmployeeDocumentType.query.filter_by(name=name).first()
    if clash is not None and clash is not kind:
        raise PayrollRefused('يوجد نوع وثيقة بهذا الاسم')
    if kind is None:
        kind = EmployeeDocumentType(is_active=True)
        db.session.add(kind)
    kind.name = name
    if 'alert_days' in data:
        days = data.get('alert_days')
        if days in (None, ''):
            kind.alert_days = None
        else:
            try:
                days = int(days)
            except (TypeError, ValueError):
                raise PayrollRefused('أيام التنبيه عدد صحيح') from None
            if days < 0:
                raise PayrollRefused('أيام التنبيه لا تكون سالبة')
            kind.alert_days = days
    if 'is_active' in data:
        kind.is_active = bool(data['is_active'])
    db.session.flush()
    return kind


def save_document(employee_id: int, data: dict, *, by: str, document=None) -> EmployeeDocument:
    """Caller commits."""
    if db.session.get(Employee, employee_id) is None:
        raise PayrollRefused('الموظف غير موجود')
    type_id = data.get('type_id', document.type_id if document else None)
    kind = db.session.get(EmployeeDocumentType, int(type_id)) if type_id else None
    if kind is None or not kind.is_active:
        raise PayrollRefused('نوع الوثيقة غير موجود')
    issued = _day(data.get('issued_on'), 'تاريخ الإصدار') if 'issued_on' in data or document is None \
        else document.issued_on
    expires = _day(data.get('expires_on'), 'تاريخ الانتهاء') if 'expires_on' in data or document is None \
        else document.expires_on
    if issued and expires and expires < issued:
        raise PayrollRefused('الانتهاء قبل الإصدار')
    if document is None:
        document = EmployeeDocument(employee_id=employee_id, created_by=by)
        db.session.add(document)
    document.type_id, document.issued_on, document.expires_on = kind.id, issued, expires
    for field in ('number', 'notes'):
        if field in data:
            setattr(document, field, (str(data.get(field) or '').strip() or None))
    db.session.flush()
    return document


def current_documents(employee) -> list:
    """The latest of each kind -- the one followed."""
    latest = {}
    for document in (employee.documents.order_by(EmployeeDocument.expires_on.asc().nullsfirst(),
                                                 EmployeeDocument.id.asc())):
        latest[document.type_id] = document
    return sorted(latest.values(), key=lambda d: (d.expires_on or date.max, d.id))


# ── what nears its end ─────────────────────────────────────────────────────────

def expiring(today: date) -> list[dict]:
    """Of the active employees: each document within its kind's alert days,
    each contract's end or probation's within contract_alert_days -- an ended
    one too, until renewed."""
    from services.payroll_policy import policy
    contract_days = policy().get('contract_alert_days')
    rows = []
    for employee in Employee.query.filter_by(is_active=True).order_by(Employee.id):
        for document in current_documents(employee):
            days = document.type.alert_days if document.type else None
            if document.expires_on is None or days is None:
                continue
            left = (document.expires_on - today).days
            if left <= days:
                rows.append({'employee_id': employee.id, 'employee': employee.name, 'kind': 'document',
                             'label': document.type.name, 'ends_on': document.expires_on.isoformat(),
                             'days_left': left})
        contract = contract_on(employee.id, today)
        if contract is None or contract_days is None:
            continue
        for kind, label, day in (('contract', 'نهاية العقد', contract.end_date),
                                 ('probation', 'نهاية فترة التجربة', contract.probation_end)):
            if day is None or (kind == 'probation' and day < today):
                continue
            left = (day - today).days
            if left <= int(contract_days):
                rows.append({'employee_id': employee.id, 'employee': employee.name, 'kind': kind,
                             'label': label, 'ends_on': day.isoformat(), 'days_left': left})
    return sorted(rows, key=lambda r: r['days_left'])
