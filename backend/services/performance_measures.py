"""One measure of an employee's work: the race, the goals and the bonuses read it (bonus study م1).

The owner (24 Oct 2026): «ابدأ واعتمد توصياتك». They measured the same
employee three ways -- the race by the points engine, the bonuses by it for
points but crediting the seller *or* the poster and summing sales and profit
by themselves, the goals by Σprofit_gold × 10 -- so a goal showed 1,032.5
points and 2,581 riyals where the bonus paid 1,223 and 3,057.5 (May 2026).

Here, once:
  actor_of(invoice)        its seller, or its poster when it has none -- the
                           race's rule (the bonuses credited both);
  activity(employee, ...)  what is theirs in a period: their posted invoices,
                           the returns of them made in it, and the corrections
                           of them made in it (ADR-056) -- each in its own
                           period, as the engine reads them;
  measure(name, ...)       points by the race's settings, or sales, the
                           weight sold, the count -- the engine's own modes.
"""
from __future__ import annotations

from datetime import date, datetime

SALE, CUSTOMER_BUY = 'بيع', 'شراء من عميل'
TYPES = {'points': (SALE, CUSTOMER_BUY), 'sales': (SALE,), 'sold_weight': (SALE,), 'count': (SALE,)}
MEASURES = tuple(TYPES)


def _key(value) -> str:
    return (str(value or '')).strip().lower()


def actor_of(inv) -> int | None:
    """The employee an invoice is credited to: its seller, else the employee of
    whoever posted it -- by user name, by the user's full name, or by the
    employee's name."""
    from sqlalchemy import func
    from models import AppUser, Employee
    if getattr(inv, 'employee_id', None) not in (None, '', 0, '0', False):
        return int(inv.employee_id)
    poster = _key(getattr(inv, 'posted_by', None))
    if not poster:
        return None
    for column in (AppUser.username, func.coalesce(AppUser.full_name, '')):
        user = AppUser.query.filter(func.lower(func.trim(column)) == poster).first()
        if user is not None and getattr(user, 'employee_id', None):
            return int(user.employee_id)
    employee = Employee.query.filter(func.lower(func.trim(func.coalesce(Employee.name, ''))) == poster).first()
    return int(employee.id) if employee is not None else None


def _names_of(employee_id: int) -> set:
    """What a poster of this employee's invoices may be written as (actor_of's three)."""
    from models import AppUser, Employee
    names = {_key(u.username) for u in AppUser.query.filter_by(employee_id=employee_id)}
    names |= {_key(u.full_name) for u in AppUser.query.filter_by(employee_id=employee_id) if u.full_name}
    employee = Employee.query.get(employee_id)
    if employee is not None and employee.name:
        names.add(_key(employee.name))
    return {n for n in names if n}


def credited_to(invoice_alias, employee_id: int):
    """actor_of in SQL, on *invoice_alias*: the seller, or no seller and one of
    the employee's names as the poster."""
    from sqlalchemy import and_, func, or_
    names = _names_of(employee_id) or {''}
    return or_(invoice_alias.employee_id == employee_id,
               and_(invoice_alias.employee_id.is_(None),
                    func.lower(func.trim(invoice_alias.posted_by)).in_(names)))


def _bounds(start, end):
    lo = datetime.combine(start, datetime.min.time()) if isinstance(start, date) and not isinstance(start, datetime) \
        else start
    hi = datetime.combine(end, datetime.max.time()) if isinstance(end, date) and not isinstance(end, datetime) \
        else end
    return lo, hi


def activity(employee_id: int, start, end, types=(SALE, CUSTOMER_BUY)) -> list:
    """The employee's posted invoices of *types* in the period, with the returns
    and the corrections of theirs made in it."""
    from models import Invoice
    from points.engine import corrections_against, returns_against
    lo, hi = _bounds(start, end)
    types = tuple(types)
    own = Invoice.query.filter(Invoice.is_posted.is_(True), Invoice.invoice_type.in_(types),
                               Invoice.date >= lo, Invoice.date <= hi, credited_to(Invoice, employee_id)).all()

    def theirs(original):
        from sqlalchemy import and_
        return and_(original.invoice_type.in_(types), credited_to(original, employee_id))
    return (own + returns_against(theirs, lo, hi, end_inclusive=True)
            + corrections_against(theirs, lo, hi, end_inclusive=True))


#: The race's settings a point is made of; [points] overrides them in a
#: preview (bonus study م3د).
POINTS_SETTINGS = ('points_source', 'cash_amount_per_point', 'points_per_gram', 'points_per_invoice')


def engine_settings(name: str, points: dict | None = None) -> dict:
    """The engine's mode and units for a measure: points by the race's settings
    (or [points] over them, to preview a change); the others in their own unit
    (riyals, grams, invoices). Points per invoice are the race's too: the goals
    and bonuses counted 1 whatever the race counted."""
    from models import get_race_points_config
    if name == 'points':
        cfg = {**get_race_points_config(), **(points or {})}
        return dict(points_source=cfg['points_source'], cash_amount_per_point=float(cfg['cash_amount_per_point']),
                    points_per_gram=float(cfg['points_per_gram']), point_rules=cfg.get('point_rules') or [],
                    points_per_invoice=float(cfg.get('points_per_invoice') or 1.0))
    return {'sales': dict(points_source='sales_amount', cash_amount_per_point=1.0, points_per_gram=1.0),
            'sold_weight': dict(points_source='sold_weight', cash_amount_per_point=1.0, points_per_gram=1.0),
            'count': dict(points_source='invoice_count', cash_amount_per_point=1.0, points_per_gram=1.0,
                          points_per_invoice=1.0)}[name]


def measure(name: str, employee_id: int, start, end, points: dict | None = None) -> float:
    """One of MEASURES for the employee in the period, returns and corrections
    taken in their own period. [points]: race settings to preview."""
    from points.engine import compute_invoices_points
    if name not in TYPES:
        raise ValueError(f'unknown measure {name!r}')
    return compute_invoices_points(activity(employee_id, start, end, TYPES[name]), **engine_settings(name, points))
