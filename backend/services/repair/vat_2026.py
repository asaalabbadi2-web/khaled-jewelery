"""VAT in the 2026 books as it was filed (ADR-089, the owner 12 Nov 2026).

The returns are filed from another program, linked to the tax authority. Our
books kept no output VAT (sales VAT is off: what the sales carried stayed in
revenue), and payment vouchers did not separate their input VAT -- so the
books said neither what was owed nor what was paid. The owner:
  - output VAT: «قيد يدوي مدينه حساب المبيعات» per quarter, at the return's
    figure, net of the returns' VAT -- on the account the quarter's sales are
    on (the old «إيرادات النشاط» until March, «مبيعات ذهب جديد» after);
  - input VAT: what the books lack against the accountant's statement, per
    quarter -- Lazurde's 9,146.14 out of the scrap purchases it sat in, the
    rest to «ضريبة مدخلات مستردة من الإقرار»;
  - Q4 2025 «مع 2026 كاملة»; each quarter closed into the net payable, and
    paid at the end of the month after it;
  - December – March administrative salaries and social insurance, paid and
    never entered, by the owner's figures.

What was paid or received and never entered had reached «عجز / فائض
الخزائن» through the reconciliations (ADR-088): it is corrected there, never
on the protected cash box or bank. Runs after the opening repair (ADR-088):
its expect_before is the books that one leaves. The shared writer
(services/repair/planned_entries) refuses, keeping nothing, when the books
differ from what the plan found; this refuses when the result differs from
what it says.
"""
from __future__ import annotations

import datetime as dt
import json
import os

from models import AuditLog, JournalEntry, JournalEntryLine, db
from services.repair.planned_entries import PlanRefused, balance, differ, load as _load, write_plan

FIGURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vat_2026.json')

VatRefused = PlanRefused


def load(path: str = FIGURES) -> dict:
    return _load(path)


def profit_change(figures: dict, accounts: dict) -> float:
    """What the plan's entries do to the year's cash profit: minus their net
    debit on the profit accounts (revenue debited, costs credited)."""
    ids = [accounts[k].id for k in figures['profit_accounts']]
    net = db.session.query(db.func.coalesce(db.func.sum(
        db.func.coalesce(JournalEntryLine.cash_debit, 0) - db.func.coalesce(JournalEntryLine.cash_credit, 0)), 0)) \
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id) \
        .filter(JournalEntry.reference_type == figures['reference_type'], JournalEntry.is_deleted.isnot(True),
                JournalEntryLine.is_deleted.isnot(True), JournalEntryLine.account_id.in_(ids)).scalar()
    return round(-float(net or 0.0), 2)


def report(figures: dict, accounts: dict) -> dict:
    def shown(bal):        # riyals alone, or every column where grams move
        if all(abs(bal[k]) < 0.0005 for k in ('18k', '21k', '22k', '24k')):
            return round(bal['cash'], 2)
        return {k: round(v, 3) for k, v in bal.items()}
    return {'accounts': {k: shown(balance(accounts[k].id)) for k in figures['expect_after']},
            'profit_change': profit_change(figures, accounts)}


def apply(*, by: str, now: dt.datetime, figures: dict | None = None) -> dict:
    """Write the plan's entries; refuse when the books differ from it before or
    after. The caller commits (the CLI rolls back a dry run)."""
    figures = figures or load()
    done = write_plan(figures, by=by, now=now)
    accounts = done['accounts']
    if done['already']:
        return {'already': True, 'entries': done['entries'], 'after': report(figures, accounts)}

    after = report(figures, accounts)
    wrong = differ(figures['expect_after'], accounts)
    if abs(after['profit_change'] - float(figures['expect_profit_change'])) > 0.02:
        wrong.append(f"أثر الربح {after['profit_change']:,.2f} والخطة {float(figures['expect_profit_change']):,.2f}")
    if wrong:
        raise VatRefused('النتيجة غير ما تقوله الخطة: ' + '؛ '.join(wrong))

    entries = [{k: e[k] for k in ('key', 'entry', 'date')} for e in done['entries']]
    result = {'entries': entries, 'made': done['made'], 'after': after}
    AuditLog.log_action(user_name=by, action=figures.get('audit_action', 'repair_vat_2026'), entity_type='JournalEntry',
                        entity_id=done['entries'][0]['id'], entity_number=figures['reference_type'],
                        details=json.dumps(result, ensure_ascii=False, default=str))
    return result
