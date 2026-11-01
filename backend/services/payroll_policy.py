"""The payroll's data and policy: salary structures, contribution schemes, the policy (PAYROLL-2).

The owner, 1 Nov 2026 («اودع ثم أكمل», his seven decisions):
  - a salary is a structure from a day on -- basic, housing, transport,
    other; a new salary is a new structure, the past keeps what it was paid by;
  - contributions are schemes an employee is in, not his nationality («الفكرة
    أعم وليس مربوطة بجنسية») -- a rate is a dated component of its scheme;
  - each employee is paid by bank (his IBAN) or cash;
  - every ratio is data («النسب ... قابلة للتعديل»): the policy is the
    settings' JSON, seeded by its migration -- a key not set is refused
    `payroll_policy_not_set`, never guessed (as the main karat, ADR-063).

tests/test_payroll_structures_and_policy.py; its guard keeps the numbers out
of the payroll's code.
"""
from __future__ import annotations

import json
from datetime import date

from models import (ContributionComponent, ContributionScheme, Employee, Payroll, SalaryStructure,
                    Settings, db)
from services.payroll_laws import PayrollRefused

RATIOS = ('housing_ratio', 'transport_ratio', 'advance_cap_ratio', 'overtime_premium_ratio',
          'eos_resign_tier1_share', 'eos_resign_tier2_share')       # art. 85's shares (EMP-5)
COUNTS = ('advance_installments', 'day_divisor', 'eos_first_years', 'contract_alert_days',
          'eos_resign_min_years', 'eos_resign_tier1_years', 'eos_resign_tier2_years')   # art. 85's years
FLAGS = ('attendance_enabled',)
MONTHS = ('eos_first_years_months', 'eos_after_years_months')     # a year's months of wage (art. 84)
CHOICES = {'eos_wage_base': ('basic', 'basic_housing', 'gross')}
KEYS = RATIOS + COUNTS + FLAGS + MONTHS + tuple(CHOICES)
MONTHS_IN_A_YEAR = 12
BASES = ('basic', 'basic_housing', 'gross')
PAYMENT_METHODS = ('bank', 'cash')
DAYS_IN_A_MONTH = 31
SAUDI_IBAN_LENGTH = 24          # SA, two check digits, 20 of the bank and the account
IBAN_CHECK_MODULUS = 97         # ISO 13616


class PayrollPolicyNotSet(PayrollRefused):
    def __init__(self, key: str):
        super().__init__(f'سياسة الرواتب غير مضبوطة ({key}): تُضبط في إعدادات الرواتب، ولا يُحسب شيء بها دونها',
                         'payroll_policy_not_set')


# ── the policy ─────────────────────────────────────────────────────────────────

def policy() -> dict:
    settings = Settings.query.first()
    raw = getattr(settings, 'payroll_policy', None) if settings is not None else None
    try:
        decoded = json.loads(raw) if raw else {}
    except (TypeError, ValueError):
        decoded = {}
    return {key: decoded[key] for key in KEYS if key in decoded}


def require(key: str):
    value = policy().get(key)
    if value is None:
        raise PayrollPolicyNotSet(key)
    return value


def set_policy(changes: dict) -> dict:
    """The owner's edit, each key checked -- a ratio 0..1, a count a whole number;
    a key given null is unset again, not zeroed (the owner, 1 Nov 2026). Caller commits."""
    current = policy()
    for key, value in (changes or {}).items():
        if key not in KEYS:
            raise PayrollRefused(f'بند غير معروف في سياسة الرواتب: {key}')
        if value is None:
            current.pop(key, None)
            continue
        current[key] = _checked(key, value)
    settings = Settings.query.first()
    if settings is None:
        raise PayrollRefused('لا إعدادات بعد')
    settings.payroll_policy = json.dumps(current)
    return current


def _checked(key, value):
    if key in FLAGS:
        if not isinstance(value, bool):
            raise PayrollRefused(f'{key}: نعم أو لا')
        return value
    if key in CHOICES:
        if value not in CHOICES[key]:
            raise PayrollRefused(f'{key}: واحد من ' + '، '.join(CHOICES[key]))
        return value
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise PayrollRefused(f'{key}: رقم') from None
    if key in RATIOS:
        if not (0 <= number <= 1):
            raise PayrollRefused(f'{key}: نسبة بين 0 و1 (0.25 = 25%)')
        return number
    if key in MONTHS:
        if not (0 <= number <= MONTHS_IN_A_YEAR):
            raise PayrollRefused(f'{key}: أشهر من الأجر عن كل سنة، من 0 إلى 12')
        return number
    if number != int(number) or number < 1:
        raise PayrollRefused(f'{key}: عدد صحيح موجب')
    if key == 'day_divisor' and number > DAYS_IN_A_MONTH:
        raise PayrollRefused(f'{key}: لا يزيد على أيام الشهر')
    return int(number)


# ── salary structures ──────────────────────────────────────────────────────────

def structure_on(employee_id: int, day: date):
    """The structure in force on the day: the latest from on or before it -- or None."""
    return (SalaryStructure.query
            .filter(SalaryStructure.employee_id == employee_id, SalaryStructure.effective_from <= day)
            .order_by(SalaryStructure.effective_from.desc()).first())


def suggest_structure(gross) -> dict:
    """A gross split by the policy's ratios of the basic, the total kept to the halala."""
    gross = _amount(gross, 'إجمالي الراتب')
    housing_ratio, transport_ratio = float(require('housing_ratio')), float(require('transport_ratio'))
    basic = round(gross / (1 + housing_ratio + transport_ratio), 2)
    housing = round(basic * housing_ratio, 2)
    transport = round(gross - basic - housing, 2)
    return {'basic': basic, 'housing': housing, 'transport': transport, 'other_allowances': 0.0, 'gross': gross}


def save_structure(employee_id: int, data: dict, *, by: str, today: date, structure=None) -> SalaryStructure:
    """A new structure (or a correction of one no salary was approved by). Caller commits.

    The employee file's salary follows the structure in force today, so the
    file and the payroll say one thing (the 31 Oct copy: two employees at 0)."""
    if db.session.get(Employee, employee_id) is None:
        raise PayrollRefused('الموظف غير موجود')
    try:
        day = date.fromisoformat(str(data.get('effective_from') or (structure.effective_from if structure else '')))
    except ValueError:
        raise PayrollRefused('تاريخ بدء الهيكل مطلوب (YYYY-MM-DD)') from None
    if structure is not None:
        refuse_structure_change(structure)
    clash = SalaryStructure.query.filter_by(employee_id=employee_id, effective_from=day).first()
    if clash is not None and clash is not structure:
        raise PayrollRefused('للموظف هيكل راتب من هذا اليوم: عدّله أو اختر يومًا آخر')
    if structure is None:
        structure = SalaryStructure(employee_id=employee_id, created_by=by)
        db.session.add(structure)
    structure.effective_from = day
    for field, label in (('basic', 'الأساسي'), ('housing', 'السكن'), ('transport', 'النقل'),
                         ('other_allowances', 'البدلات الأخرى')):
        if field in data or getattr(structure, field) is None:
            setattr(structure, field, _amount(data.get(field), label))
    if not structure.basic:
        raise PayrollRefused('الأساسي مطلوب')
    if 'notes' in data:
        structure.notes = data.get('notes')
    db.session.flush()
    _follow_in_the_file(employee_id, today)
    return structure


def delete_structure(structure, *, today: date) -> None:
    refuse_structure_change(structure)
    employee_id = structure.employee_id
    db.session.delete(structure)
    db.session.flush()
    _follow_in_the_file(employee_id, today)


def refuse_structure_change(structure) -> None:
    """The past keeps what it was paid by: a structure is not changed once a
    salary of its months was approved -- a new salary is a new structure."""
    since = structure.effective_from
    approved = (Payroll.query
                .filter(Payroll.employee_id == structure.employee_id,
                        Payroll.status.in_(('approved', 'paid')),
                        (Payroll.year * 100 + Payroll.month) >= since.year * 100 + since.month)
                .first())
    if approved is not None:
        raise PayrollRefused(f'اعتُمد راتب {approved.month}/{approved.year} بهذا الهيكل: '
                             'لا يُعدَّل ولا يُحذف، والراتب الجديد هيكل جديد من يومه')


def _follow_in_the_file(employee_id: int, today: date) -> None:
    current = structure_on(employee_id, today)
    if current is not None:
        db.session.get(Employee, employee_id).salary = current.gross


def _amount(value, label: str) -> float:
    try:
        number = round(float(value or 0.0), 2)
    except (TypeError, ValueError):
        raise PayrollRefused(f'{label}: رقم') from None
    if number < 0:
        raise PayrollRefused(f'{label}: لا يكون سالبًا')
    return number


# ── contribution schemes ───────────────────────────────────────────────────────

def save_component(scheme, data: dict, component=None) -> ContributionComponent:
    """A rate of a scheme from a day on -- a new rate is a new row from its day. Caller commits."""
    if component is None:
        component = ContributionComponent(scheme_id=scheme.id)
        db.session.add(component)
    for field in ('code', 'name'):
        if field in data or getattr(component, field) is None:
            text = str(data.get(field) or '').strip()
            if not text:
                raise PayrollRefused('رمز البند واسمه مطلوبان')
            setattr(component, field, text)
    if 'base' in data or component.base is None:
        if data.get('base') not in BASES:
            raise PayrollRefused('وعاء الاشتراك: الأساسي، أو الأساسي والسكن، أو الإجمالي')
        component.base = data['base']
    for field in ('employee_rate', 'employer_rate'):
        if field in data or getattr(component, field) is None:
            if data.get(field) in (None, ''):
                # an empty rate is not a zero (the owner, 1 Nov 2026): a zero is typed 0
                raise PayrollRefused('نسبتا الموظف والمنشأة مطلوبتان؛ اكتب 0 لما لا نسبة له')
            rate = _amount(data.get(field), 'النسبة')
            if rate > 100:
                raise PayrollRefused('النسبة مئوية: من 0 إلى 100')
            setattr(component, field, rate)
    if 'base_cap' in data:
        component.base_cap = _amount(data['base_cap'], 'سقف الوعاء') if data['base_cap'] not in (None, '') else None
    if 'effective_from' in data or component.effective_from is None:
        try:
            component.effective_from = date.fromisoformat(str(data.get('effective_from') or ''))
        except ValueError:
            raise PayrollRefused('تاريخ بدء النسبة مطلوب (YYYY-MM-DD)') from None
    db.session.flush()
    return component


def contributions(employee, structure, day: date) -> list[dict]:
    """Each contribution of his scheme on the day: its base (capped), his share, the employer's.

    The base is the wage registered for his contributions when the owner
    entered one (PAYROLL-3) -- else each component's own, from the structure."""
    if employee.contribution_scheme_id is None or structure is None:
        return []
    scheme = db.session.get(ContributionScheme, employee.contribution_scheme_id)
    if scheme is None or not scheme.is_active:
        return []
    in_force: dict[str, ContributionComponent] = {}
    for component in (scheme.components.filter(ContributionComponent.effective_from <= day)
                      .order_by(ContributionComponent.effective_from)):
        in_force[component.code] = component
    bases = {'basic': structure.basic, 'basic_housing': structure.basic + structure.housing,
             'gross': structure.gross}
    if employee.contribution_wage:
        bases = dict.fromkeys(bases, float(employee.contribution_wage))
    rows = []
    for component in in_force.values():
        base = bases[component.base]
        if component.base_cap is not None:
            base = min(base, component.base_cap)
        rows.append({'code': component.code, 'name': component.name, 'base_amount': round(base, 2),
                     'employee_rate': component.employee_rate, 'employer_rate': component.employer_rate,
                     'employee_share': round(base * component.employee_rate / 100, 2),
                     'employer_share': round(base * component.employer_rate / 100, 2)})
    return rows


# ── how an employee is paid ────────────────────────────────────────────────────

def apply_payment_fields(employee, data: dict) -> None:
    """His scheme, his payment method and IBAN, each checked. Caller commits."""
    if 'contribution_scheme_id' in data:
        scheme_id = data.get('contribution_scheme_id') or None
        if scheme_id is not None and db.session.get(ContributionScheme, int(scheme_id)) is None:
            raise PayrollRefused('خطة الاشتراك غير موجودة')
        employee.contribution_scheme_id = int(scheme_id) if scheme_id is not None else None
    if 'payment_method' in data:
        method = data.get('payment_method') or None
        if method is not None and method not in PAYMENT_METHODS:
            raise PayrollRefused('طريقة الصرف: تحويل بنكي أو نقد')
        employee.payment_method = method
    if 'iban' in data:
        employee.iban = checked_iban(data.get('iban'))
    if 'bank_name' in data:
        employee.bank_name = (data.get('bank_name') or '').strip() or None
    if 'contribution_wage' in data:
        wage = data.get('contribution_wage')
        employee.contribution_wage = _amount(wage, 'الأجر الخاضع للاشتراك') if wage not in (None, '') else None


def checked_iban(value) -> str | None:
    """A Saudi IBAN (SA + 22), its check digits verified -- None when empty."""
    iban = ''.join(str(value or '').split()).upper()
    if not iban:
        return None
    if len(iban) != SAUDI_IBAN_LENGTH or not iban.startswith('SA') or not iban.isalnum():
        raise PayrollRefused('الآيبان السعودي 24 خانة يبدأ بـ SA')
    rearranged = iban[4:] + iban[:4]
    digits = ''.join(str(int(ch, 36)) for ch in rearranged)
    if int(digits) % IBAN_CHECK_MODULUS != 1:
        raise PayrollRefused('الآيبان غير صحيح: خانتا التحقق لا تطابقانه')
    return iban
