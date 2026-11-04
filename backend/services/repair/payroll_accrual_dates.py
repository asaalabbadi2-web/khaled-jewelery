"""Payroll accruals put on their month's last day (REPORTS ت6-2أ; the owner, 4 Nov 2026).

An accrual was dated the day it was approved: October's run, approved on 2
November, put October's salaries (41,667.00 on the 2 Nov copy) in November's
income statement; the salaries accrued one by one before the runs, April's to
September's, each fell in the month after (4 May, 5 July, 5 August, 2
September, 4 October). The law now dates an accrual its month's last day
(services/payroll_run.accrual_date), a run's and an entry's alike. This puts
the accruals approved before it there, with their reversals -- an accrual's
date is derived from its month, so the entry's date is corrected rather than
reversed and posted again (which would give a run or an entry two accruals).
dry_run (the default) changes nothing; an audit row names each.
"""
import json

from models import AuditLog, JournalEntry, Payroll, PayrollRun, db

ACTION = 'repair_payroll_accrual_dates'


def redate_accruals(*, by: str, dry_run: bool = True) -> dict:
    from services.payroll_laws import ACCRUAL, REVERSAL
    from services.payroll_run import RUN_ACCRUAL, RUN_REVERSAL, accrual_date
    redated = []
    sources = [('run_id', run, (RUN_ACCRUAL, RUN_REVERSAL)) for run in PayrollRun.query.order_by(PayrollRun.id)]
    sources += [('payroll_id', entry, (ACCRUAL, REVERSAL)) for entry in Payroll.query.order_by(Payroll.id)]
    for key, source, kinds in sources:
        due = accrual_date(source)
        entries = JournalEntry.query.filter(JournalEntry.reference_type.in_(kinds),
                                            JournalEntry.reference_id == source.id,
                                            JournalEntry.is_deleted.is_(False)).all()
        off = [e for e in entries if e.date.date() != due.date()]       # its day is the law, not its hour
        if not off:
            continue
        redated.append({key: source.id, 'month': f'{source.year}-{source.month:02d}',
                        'entries': [{'id': e.id, 'kind': e.reference_type, 'from': e.date.isoformat(),
                                     'to': due.isoformat()} for e in off]})
        if not dry_run:
            for entry in off:
                entry.date = due
    plan = {'redated': redated}
    if dry_run or not redated:
        return plan
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='payroll', entity_id=len(redated),
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
