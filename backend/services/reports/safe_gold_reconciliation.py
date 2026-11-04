"""The gold safes' statements against the books, karat by karat, on a day (REPORTS ت5-3, ADR-083).

«ميزان مراجعة الأوزان (خزنة ↔ حساب)» computed its own -- every statement
row, and the account's lines whether they counted or not (a deleted or
unposted entry summed), its end day cut at midnight. This reads the nightly
check's one computation (services/safebox_subledger.gold_subledger_by_box:
the statement rows it counts against the posted, not-deleted entries on the
safe's account), to the end of a day: per gold safe its totals in the main
karat, then each karat that holds anything -- the statement, the books, the
difference. Its check is the nightly one's threshold. A safe opens its account.
"""
from __future__ import annotations

import datetime as dt

from services.reports.contract import Check, Column, Report


def safe_gold_reconciliation(*, as_of: dt.date, now: dt.datetime) -> Report:
    """*now*: the caller's clock (ADR-015)."""
    from models import SafeBox
    from pricing.karat_service import convert_to_main_karat
    from services.safebox_subledger import GOLD_DRIFT_THRESHOLD, gold_subledger_by_box
    before = dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min)
    boxes = {b.id: b for b in SafeBox.query.filter(SafeBox.safe_type == 'gold').order_by(SafeBox.name)}
    rows, agree = [], True
    totals = {'statement': 0.0, 'ledger': 0.0, 'difference': 0.0}
    for sid, by_karat in sorted(gold_subledger_by_box(list(boxes), before).items(),
                                key=lambda kv: boxes[kv[0]].name if kv[0] in boxes else ''):
        held = {k: v for k, v in by_karat.items() if abs(v[0]) > 0.0005 or abs(v[1]) > 0.0005}
        if not held:
            continue
        box = boxes.get(sid)
        main = {key: sum(convert_to_main_karat(v[i], int(k.rstrip('k'))) for k, v in held.items())
                for i, key in ((0, 'statement'), (1, 'ledger'))}
        main['difference'] = main['statement'] - main['ledger']
        for key in totals:
            totals[key] += main[key]
        rows.append({'safe_box_id': sid, 'name': box.name if box else str(sid), 'style': 'heading',
                     **{k: round(v, 3) or 0.0 for k, v in main.items()},
                     'drill': {'kind': 'account', 'id': box.account_id} if box and box.account_id else None})
        for karat, (statement, ledger) in sorted(held.items(), key=lambda kv: -int(kv[0].rstrip('k'))):
            difference = round(statement - ledger, 3)
            agree &= abs(difference) <= GOLD_DRIFT_THRESHOLD
            rows.append({'safe_box_id': sid, 'karat': karat, 'name': f'عيار {karat.rstrip("k")}',
                         'statement': round(statement, 3), 'ledger': round(ledger, 3),
                         'difference': difference or 0.0,
                         'style': 'finding' if abs(difference) > GOLD_DRIFT_THRESHOLD else None})
    columns = [Column('name', 'الخزينة / العيار'), Column('statement', 'دفتر الخزينة (جم)', 'grams'),
               Column('ledger', 'الدفاتر (جم)', 'grams'), Column('difference', 'الفرق', 'grams', signed=True)]
    checks = [Check('statements_agree', f'دفتر كل خزينة ذهب = حسابها في الدفاتر (حدّ {GOLD_DRIFT_THRESHOLD} جم)',
                    agree)]
    return Report(id='safe_gold_reconciliation', title='ميزان مراجعة الأوزان (خزنة ↔ حساب)',
                  basis='posted_entries', columns=columns, rows=rows,
                  totals={k: round(v, 3) for k, v in totals.items()}, checks=checks, end=as_of, read_at=now)
