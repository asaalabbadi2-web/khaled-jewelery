"""The gold sold that sat on the customers' weight twins, moved by month (CUSTGOLD-001, the owner 5 Nov 2026).

The owner: «تصحيح الكاتب ونقل الرصيد» and «قيد لكل شهر». Until the writer
was put right (je_engine_v2.build_sale_je), a sale debited its customer's
weight twin (712…) for the grams it took out of the stock: 19,495 g on the
2 Nov copy -- the sales (+25,460), June's historical reconciliation and two
rejected sales reversed (-5,703), the returns (-52), and 16 customer
purchases of March-April that credited the twin (-209).

Each month's net, account by account and column by column (each karat and
the main-karat weight), moves by one entry dated the month's last day at
23:59 -- the month not over yet, at *now* -- so each month's balance sheet
is right: a sale's (its return's, its correction's, a reversal of it) to
the cost of sales by weight (gold_cost_of_sales_weight); a customer
purchase's to its purchases by weight (its pool's purchases role's twin).
A line from anything else is said in 'left', not moved. The tool's own
entries are in the net: run twice, it moves nothing more. dry_run (the
default) writes nothing; an audit row says what moved.
"""
from __future__ import annotations

import collections
import calendar
import datetime as dt
import json

from models import Account, AuditLog, Invoice, InvoiceCorrection, JournalEntry, JournalEntryLine, db

MOVED = 'customer_gold_moved'
ACTION = 'repair_customer_gold_to_cost_of_sales'
COLUMNS = ('18k', '21k', '22k', '24k', 'weight')
SALES = ('بيع', 'مرتجع بيع')
PURCHASES = ('شراء من عميل', 'مرتجع شراء')
EPS = 0.0005


class MoveRefused(ValueError):
    pass


def _purchases_twin(gold_type: str) -> int:
    from accounting.mappings import get_account_id_for_mapping, require_account
    if gold_type == 'scrap':
        financial = require_account('شراء من عميل', 'purchases_gold_scrap')
    else:
        financial = (get_account_id_for_mapping('شراء من عميل', 'purchases_gold_new')
                     or require_account('شراء من عميل', 'purchases_gold'))
    twin = db.session.get(Account, financial).memo_account_id
    if not twin:
        raise MoveRefused(f'حساب المشتريات {db.session.get(Account, financial).account_number} بلا توأم وزني')
    return int(twin)


def _kinds(entries: dict) -> dict:
    """{entry id: 'sold' | 'bought-scrap' | 'bought-new' | None} -- by the invoice it is, corrects or reverses."""
    reversed_ids = {e.reference_id for e in entries.values() if e.reference_type == 'journal_entry_reversal'}
    originals = {e.id: e for e in JournalEntry.query.filter(JournalEntry.id.in_(reversed_ids or {-1}))}
    corrections = {c.id: c.invoice_id for c in InvoiceCorrection.query.filter(InvoiceCorrection.id.in_(
        {e.reference_id for e in entries.values() if e.reference_type == 'invoice_correction'} or {-1}))}

    def invoice_of(e):
        if e is None:
            return None
        if e.reference_type == 'invoice':
            return e.reference_id
        if e.reference_type == 'invoice_correction':
            return corrections.get(e.reference_id)
        if e.reference_type == 'journal_entry_reversal':
            return invoice_of(originals.get(e.reference_id))
        return None

    invoice_ids = {i for i in (invoice_of(e) for e in entries.values()) if i}
    invoices = {i.id: i for i in Invoice.query.filter(Invoice.id.in_(invoice_ids or {-1}))}
    out = {}
    for e in entries.values():
        if e.reference_type == MOVED:
            out[e.id] = e.reference_number.rsplit('-', 1)[-1] if e.reference_number else None
            out[e.id] = {'sold': 'sold', 'scrap': 'bought-scrap', 'new': 'bought-new'}.get(out[e.id])
            continue
        inv = invoices.get(invoice_of(e))
        kind = (inv.invoice_type or '').strip() if inv else None
        out[e.id] = ('sold' if kind in SALES else
                     f"bought-{'scrap' if inv.gold_type == 'scrap' else 'new'}" if kind in PURCHASES else None)
    return out


def _date(month: str, now: dt.datetime) -> dt.datetime:
    y, m = map(int, month.split('-'))
    last = dt.datetime(y, m, calendar.monthrange(y, m)[1], 23, 59)
    return min(last, now)


def move(*, by: str, now: dt.datetime, dry_run: bool = True) -> dict:
    """*now*: the run's clock, passed in (ADR-015)."""
    from accounting.balances import counted_line_filters
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT, twin_subtree_ids
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
    from pricing.karat_service import convert_to_main_karat
    from services.repair.entries import write_entry

    twins = twin_subtree_ids(CUSTOMER_RECEIVABLES_ROOT)
    rows = (db.session.query(JournalEntryLine, JournalEntry)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(twins or {-1})).all())
    entries = {e.id: e for _, e in rows}
    kinds = _kinds(entries)

    nets = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    left = []
    for line, entry in rows:
        grams = {c: float(getattr(line, f'debit_{c}') or 0) - float(getattr(line, f'credit_{c}') or 0) for c in COLUMNS}
        if all(abs(g) < EPS for g in grams.values()):
            continue
        kind = kinds.get(entry.id)
        if kind is None:
            left.append({'entry_id': entry.id, 'entry_number': entry.entry_number, 'date': entry.date.isoformat(),
                         'reference_type': entry.reference_type, 'account_id': line.account_id,
                         'grams': {c: round(g, 3) for c, g in grams.items() if abs(g) >= EPS}})
            continue
        nets[(entry.date.strftime('%Y-%m'), kind)][line.account_id].update(grams)

    sold_to = require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_cost_of_sales_weight') if nets else None
    months = []
    for (month, kind), by_account in sorted(nets.items()):
        lines, counter = [], collections.Counter()
        for account_id, grams in sorted(by_account.items()):
            spec = {'account_id': account_id, 'description': f'نقل ذهب مباع {month} (CUSTGOLD-001)'}
            for c in COLUMNS:
                g = round(grams[c], 6)
                if abs(g) < EPS:
                    continue
                spec[f'credit_{c}' if g > 0 else f'debit_{c}'] = abs(g)
                counter[c] += g
            if len(spec) > 2:
                lines.append(spec)
        if not lines:
            continue
        target = sold_to if kind == 'sold' else _purchases_twin(kind.split('-', 1)[1])
        spec = {'account_id': target, 'description': f'من حسابات وزن العملاء {month} (CUSTGOLD-001)'}
        for c, g in counter.items():
            if abs(g) >= EPS:
                spec[f'debit_{c}' if g > 0 else f'credit_{c}'] = abs(g)
        lines.append(spec)
        main = sum(convert_to_main_karat(counter[f'{k}k'], k) for k in (18, 21, 22, 24))
        months.append({'month': month, 'kind': kind, 'to': target, 'accounts': len(lines) - 1,
                       'grams_main': round(main, 3), 'date': _date(month, now).isoformat()})
        if not dry_run:
            months[-1]['entry_id'] = write_entry(date=_date(month, now), description=f'نقل الذهب المباع من حسابات وزن العملاء — {month}',
                        reference_type=MOVED, reference_id=None, reference_number=f'CUSTGOLD-{month}-{kind.split("-")[-1]}',
                        lines=lines, by=by, now=now, safe_rows=False).id
    plan = {'months': months, 'left': left,
            'sold_g': round(sum(m['grams_main'] for m in months if m['kind'] == 'sold'), 3),
            'bought_g': round(sum(m['grams_main'] for m in months if m['kind'] != 'sold'), 3)}
    if dry_run or not months:
        return plan
    db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='journal_entry', entity_id=months[0]['entry_id'],
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan
