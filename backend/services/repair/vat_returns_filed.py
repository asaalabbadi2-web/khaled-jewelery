"""The four 2026 returns, filed through ADR-089, as filed returns (ADR-043 rule 5).

tools/repair/vat_2026.py booked Q4 2025 .. Q3 2026 from the returns the
accountant filed, each closing into 2301 by its «V<quarter>-close» entry. The
VAT return screen knows a period as filed only by its row in vat_return, so
without one it would file those quarters a second time. This writes the row,
from the same figures (vat_2026.json «returns»): the output VAT (the sales'
less the returns'), the input VAT, the due -- linked to the closing entry.
No entry is written. A quarter already recorded with the same figures is
left; one recorded otherwise, or overlapped, is refused; so is a quarter whose
closing entry is not in the books (run vat_2026 first).
"""
from __future__ import annotations

import datetime as dt
import json

from models import AuditLog, VatReturn, db
from services.repair.planned_entries import PlanRefused, written
from services.repair.vat_2026 import load

CENT = 0.005


def quarter_period(name: str) -> tuple[dt.date, dt.date]:
    """'Q4-2025' -> (2025-10-01, 2025-12-31)."""
    q, year = name.split('-')
    n, year = int(q[1:]), int(year)
    if not 1 <= n <= 4:
        raise PlanRefused(f'ربع غير معروف: {name}')
    start = dt.date(year, 3 * n - 2, 1)
    end = dt.date(year + 1, 1, 1) if n == 4 else dt.date(year, 3 * n + 1, 1)
    return start, end - dt.timedelta(days=1)


def filed(figures: dict) -> list[dict]:
    """Each quarter as its return says it, from the plan's own figures."""
    out = []
    for name, q in figures['returns'].items():
        start, end = quarter_period(name)
        output = round(float(q['sales_vat']) - float(q['returns_vat']), 2)
        input_ = round(float(q['input_vat']), 2)
        net = round(float(q['due']), 2)
        if abs(round(output - input_, 2) - net) > CENT:
            raise PlanRefused(f'{name}: المخرجات {output:,.2f} ناقص المدخلات {input_:,.2f} ليس المستحق {net:,.2f}')
        out.append({'quarter': name, 'start': start, 'end': end, 'output_vat': output, 'input_vat': input_,
                    'net': net, 'key': f"V{name}-close"})
    return out


def record(*, by: str, now: dt.datetime, figures: dict | None = None) -> dict:
    """Write the missing rows. The caller commits (the CLI rolls back a dry run)."""
    figures = figures or load()
    done, left, todo = [], [], []
    for q in filed(figures):                       # every quarter checked before any row is written
        entry = written(figures['reference_type'], q['key'])
        if entry is None:
            raise PlanRefused(f"{q['quarter']}: قيد الإقفال {q['key']} ليس في الدفاتر -- شغّل vat_2026 أولًا")
        overlap = VatReturn.query.filter(VatReturn.period_start <= q['end'], VatReturn.period_end >= q['start']).all()
        same = [r for r in overlap if (r.period_start, r.period_end) == (q['start'], q['end'])
                and all(abs(float(getattr(r, k)) - q[k]) <= CENT for k in ('output_vat', 'input_vat', 'net'))
                and r.journal_entry_id == entry.id]
        if overlap and len(same) == len(overlap) == 1:
            left.append(q['quarter'])
        elif overlap:
            r = overlap[0]
            raise PlanRefused(f"{q['quarter']}: إقرار مسجّل {r.period_start} – {r.period_end} بغير أرقام الخطة")
        else:
            todo.append((q, entry))
    for q, entry in todo:
        db.session.add(VatReturn(period_start=q['start'], period_end=q['end'], output_vat=q['output_vat'],
                                 input_vat=q['input_vat'], net=q['net'], journal_entry_id=entry.id,
                                 filed_by=by, filed_at=now))
        done.append({**{k: q[k] for k in ('quarter', 'output_vat', 'input_vat', 'net')},
                     'start': q['start'].isoformat(), 'end': q['end'].isoformat(), 'entry': entry.entry_number})
    db.session.flush()
    result = {'recorded': done, 'already': left}
    if done:
        AuditLog.log_action(user_name=by, action='repair_vat_returns_filed', entity_type='VatReturn',
                            entity_id=VatReturn.query.order_by(VatReturn.id.desc()).first().id,
                            entity_number=figures['reference_type'],
                            details=json.dumps(result, ensure_ascii=False, default=str))
    return result
