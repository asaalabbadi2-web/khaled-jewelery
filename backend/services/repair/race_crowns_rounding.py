"""The months crowned twice by the rounding, kept with their leader alone (the owner, 3 Nov 2026).

«يوسف ١٠ اشهر وعبدالله ١ شهر ... رغم اننا انهينا ١٠ اشهر»: a month's points
were rounded to whole points before they were compared (services/race_honours,
before 3 Nov), so a lead of less than a point was kept as a tie and crowned
both. On the 2 Nov copy one month: June 2026, عبدالله 1,079.29 and يوسف
1,078.596.

A month kept with more than one crown is measured again as the points are,
among those it crowned: the crowns of those not at the top go; the leader's
kept value becomes his points as they are. A month with one crown is its
record («سجل محفوظ»), not measured again. dry_run (the default) writes
nothing; an audit row says what went. Caller commits.
"""
from __future__ import annotations

import json

from models import AuditLog, Employee, RaceHonour, db

ACTION = 'repair_race_crowns_rounding'


def correct_rounded_ties(*, by: str, dry_run: bool = True) -> dict:
    from services.performance_measures import measure
    from services.race_honours import POINTS_PLACES
    months = (db.session.query(RaceHonour.period_start)
              .filter(RaceHonour.kind == 'leader', RaceHonour.period == 'monthly')
              .group_by(RaceHonour.period_start).having(db.func.count(RaceHonour.id) > 1).all())
    names = {e.id: e.name for e in Employee.query.all()}
    removed, kept = [], []
    for (start,) in months:
        crowns = RaceHonour.query.filter_by(kind='leader', period='monthly', period_start=start).all()
        points = {h.id: round(measure('points', h.employee_id, h.period_start, h.period_end), POINTS_PLACES)
                  for h in crowns}
        top = max(points.values())
        for honour in crowns:
            row = {'month': f'{start:%Y-%m}', 'employee_id': honour.employee_id,
                   'name': names.get(honour.employee_id), 'kept_value': honour.value, 'points': points[honour.id]}
            if points[honour.id] < top:
                removed.append(row)
                if not dry_run:
                    db.session.delete(honour)
            else:
                kept.append(row)
                if not dry_run:
                    honour.value = points[honour.id]
    plan = {'removed': removed, 'kept': kept}
    if not dry_run and removed:
        db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='race_honour',
                                entity_id=removed[0]['employee_id'], success=True,
                                details=json.dumps(plan, ensure_ascii=False, default=str)))
    if not dry_run:
        db.session.flush()
    return plan
