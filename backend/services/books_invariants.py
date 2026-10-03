"""The books, checked against each other — every night, and never touched.

Every incident of September 2026 was found by a person reconciling by hand,
weeks or months late; none by the system. The attribution table held zero rows
for its whole life. 92,385.00 of posted receipts read as zero in the safe-box
statements for four months. A rejected invoice distorted a supplier's balance,
and deleting it doubled the distortion. Each was visible in the data the day it
happened, to anything that looked.

This module looks. Each check below asserts one agreement between records that
must agree, and returns the FACTS where they do not -- never a count, so a
finding can always name what it is about.

It REPORTS. It never repairs. A job that silently heals a divergence destroys
the only evidence that some writer is wrong, and the wrong writer then keeps
writing. Findings go to ReconciliationFinding, the table designed as "one
source of truth for all operational gaps"; tests/test_books_invariants.py::
TestReportOnly proves no financial table is touched.

THE ALARM IS A CHANGE, NOT A STATE. The first run will report historical damage
-- five safe boxes have drifted for months. That is a baseline, visible until
corrected. What matters each morning is what is NEW, or what MOVED: a drift that
grows is a writer still damaging the statement tonight. So a finding whose
magnitude changes is closed with its old value and reopened with the new one,
and "what happened last night" is simply the findings opened by the last run.

Witnessed on the reference bench (seven restored production snapshots): the
difference in findings between the snapshot before and after invoice 3132 was
deleted is exactly {+ORPHAN_POSTED_ENTRY 7413, -UNPOSTED_ENTRY_IN_LIMBO 7410,
7411, 7414} -- the reversal that doubled the supplier's gold, and the entries
that had been distorting it since the invoice was rejected. The pre-existing
safe-box comparison did not move across that incident: the delete removed both
sides. Entry-level checks exist because balance comparisons are blind to that.
"""
from __future__ import annotations

import json
from datetime import datetime
from typing import NamedTuple, Optional

from sqlalchemy.orm import aliased
from sqlalchemy import and_, exists, func, or_

from models import (
    Invoice,
    JournalEntry,
    JournalEntryLine,
    ReconciliationFinding,
    SafeBox,
    Voucher,
    VoucherAccountLine,
    VoucherInvoiceGoldAttribution,
    db,
)
from services.safebox_subledger import (
    DRIFT_THRESHOLD, GOLD_DRIFT_THRESHOLD, gold_subledger_by_box, subledger_totals_by_box,
)

SOURCE = 'books_invariants'

ORPHAN_POSTED_ENTRY = 'ORPHAN_POSTED_ENTRY'
UNPOSTED_ENTRY_IN_LIMBO = 'UNPOSTED_ENTRY_IN_LIMBO'
POSTED_ENTRY_OF_UNPOSTED_INVOICE = 'POSTED_ENTRY_OF_UNPOSTED_INVOICE'
GOLD_ATTRIBUTION_MISSING = 'GOLD_ATTRIBUTION_MISSING'
SAFEBOX_SUBLEDGER_DRIFT = 'SAFEBOX_SUBLEDGER_DRIFT'
SAFEBOX_GOLD_DRIFT = 'SAFEBOX_GOLD_DRIFT'

KINDS = (
    ORPHAN_POSTED_ENTRY,
    UNPOSTED_ENTRY_IN_LIMBO,
    GOLD_ATTRIBUTION_MISSING,
    SAFEBOX_SUBLEDGER_DRIFT,
    SAFEBOX_GOLD_DRIFT,
)

# An invoice in one of these states is retracted: its entries must not count
# anywhere. Any other unposted invoice is awaiting approval.
RETRACTED_INVOICE_STATUSES = ('rejected', 'cancelled')

# A magnitude that moves by less than this has not moved. Policy (ADR-030).
METRIC_EPSILON = 0.005

# DRIFT_THRESHOLD is services/safebox_subledger.py's: the reconciliation screen
# reads the same one, so the two cannot disagree about what counts as drift.


class Fact(NamedTuple):
    kind: str
    subject_key: str
    metric: Optional[float]
    detail: dict


def _entry_cash(entry_ids) -> dict:
    """{journal_entry_id: sum of its live lines' cash debit} -- the size of an entry."""
    if not entry_ids:
        return {}
    rows = (
        db.session.query(JournalEntryLine.journal_entry_id,
                         func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0))
        .filter(JournalEntryLine.journal_entry_id.in_(list(entry_ids)))
        .filter(func.coalesce(JournalEntryLine.is_deleted, False) == False)  # noqa: E712
        .group_by(JournalEntryLine.journal_entry_id)
        .all()
    )
    return {int(r[0]): round(float(r[1] or 0.0), 2) for r in rows}


# ======================================================================
# The checks
# ======================================================================

def _not_reversed():
    """An entry with a posted reversal no longer counts -- corrected by an entry,
    as stage 4 corrects (services/repair/rejected_invoice_reversal.py)."""
    rev = aliased(JournalEntry)
    return ~exists().where(and_(rev.reference_type == 'journal_entry_reversal', rev.reference_id == JournalEntry.id,
                                func.coalesce(rev.is_posted, False) == True,  # noqa: E712
                                func.coalesce(rev.is_deleted, False) == False))  # noqa: E712


def _moves_something():
    """An entry with no non-zero live line moves no balance: nothing to report.
    REV-00014 is one -- a reversal of voucher 638 written with no lines."""
    line = aliased(JournalEntryLine)
    cols = [line.cash_debit, line.cash_credit] + [
        getattr(line, f'{side}_{k}') for side in ('debit', 'credit') for k in ('18k', '21k', '22k', '24k', 'weight')]
    return exists().where(and_(line.journal_entry_id == JournalEntry.id,
                               func.coalesce(line.is_deleted, False) == False,  # noqa: E712
                               or_(*[func.coalesce(c, 0.0) != 0 for c in cols])))


def check_orphan_posted_entries() -> list:
    """A posted entry whose document is gone.

    It still counts in every balance it touches, and nothing can ever reverse it
    through its document again. Reversal 7413 was this: left posted when invoice
    3132's delete took its original, it doubled supplier 15's gold distortion
    (-20.742 -> -41.485 g-eq).
    """
    rows = (
        db.session.query(JournalEntry.id, JournalEntry.entry_number,
                         JournalEntry.reference_type, JournalEntry.reference_id)
        .filter(func.coalesce(JournalEntry.is_deleted, False) == False)  # noqa: E712
        .filter(func.coalesce(JournalEntry.is_posted, False) == True)  # noqa: E712
        .filter(_not_reversed())
        .filter(_moves_something())
        .filter(or_(
            and_(JournalEntry.reference_type.in_(['voucher', 'voucher_reversal']),
                 ~exists().where(Voucher.id == JournalEntry.reference_id)),
            and_(JournalEntry.reference_type.in_(['invoice', 'invoice_payments']),
                 JournalEntry.reference_id.isnot(None),
                 ~exists().where(Invoice.id == JournalEntry.reference_id)),
        ))
        .all()
    )
    cash = _entry_cash([r.id for r in rows])
    return [
        Fact(ORPHAN_POSTED_ENTRY, f'journal_entry:{r.id}', cash.get(int(r.id), 0.0), {
            'entry_number': r.entry_number,
            'missing': f'{r.reference_type}:{r.reference_id}',
            'cash_debit': cash.get(int(r.id), 0.0),
        })
        for r in rows
    ]


def check_unposted_entries_in_limbo() -> list:
    """posted=False yet not a draft.

    The one state the readers disagree about: party_live_balances counts it
    (or_(is_posted, not is_draft)), the account and safe-box readers do not. So
    the same entry moves a supplier's balance and not the ledger. Invoice 3132's
    three entries sat here from the moment it was rejected, distorting supplier
    15 by -20.742 g-eq and -1,322.50 -- before anything was deleted.

    Not when the entry's document is simply awaiting approval: an invoice that is
    unposted and not retracted, or a pending voucher, has unposted entries by
    design. The first run on a production copy (29 Sep 2026) would otherwise have
    reported invoice 3158 -- a paid sale waiting to be approved -- as damage.
    What stays: a rejected or cancelled invoice's entries (3132), entries whose
    document is gone (3123's payments), and unposted entries of a posted invoice.
    """
    awaiting_approval = or_(
        and_(JournalEntry.reference_type.in_(['invoice', 'invoice_payments']),
             exists().where(and_(
                 Invoice.id == JournalEntry.reference_id,
                 func.coalesce(Invoice.is_posted, False) == False,  # noqa: E712
                 func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES)),
             ))),
        # A pending voucher awaits approval -- unless the invoice it pays has been
        # retracted or is gone: rejecting 3132 reset its payment vouchers to
        # 'pending', and their entries 7411 and 7414 kept moving supplier 15.
        and_(JournalEntry.reference_type == 'voucher',
             exists().where(and_(
                 Voucher.id == JournalEntry.reference_id,
                 Voucher.status == 'pending',
                 # coalesce: a voucher with no reference makes the comparison NULL,
                 # and NOT(NULL) would silently drop it from 'awaiting approval'.
                 ~and_(func.coalesce(Voucher.reference_type, '') == 'invoice', or_(
                     ~exists().where(Invoice.id == Voucher.reference_id),
                     exists().where(and_(
                         Invoice.id == Voucher.reference_id,
                         func.coalesce(Invoice.status, '').in_(list(RETRACTED_INVOICE_STATUSES)),
                     )),
                 )),
             ))),
    )
    rows = (
        db.session.query(JournalEntry.id, JournalEntry.entry_number,
                         JournalEntry.reference_type, JournalEntry.reference_id)
        .filter(func.coalesce(JournalEntry.is_deleted, False) == False)  # noqa: E712
        .filter(func.coalesce(JournalEntry.is_posted, False) == False)  # noqa: E712
        .filter(func.coalesce(JournalEntry.is_draft, False) == False)  # noqa: E712
        .filter(~awaiting_approval)
        .all()
    )
    cash = _entry_cash([r.id for r in rows])
    return [
        Fact(UNPOSTED_ENTRY_IN_LIMBO, f'journal_entry:{r.id}', cash.get(int(r.id), 0.0), {
            'entry_number': r.entry_number,
            'reference': f'{r.reference_type}:{r.reference_id}',
            'cash_debit': cash.get(int(r.id), 0.0),
        })
        for r in rows
    ]


def check_posted_entries_of_unposted_invoices() -> list:
    """posted=True while its invoice is not posted -- the mirror of limbo.

    It counts in every balance for a sale or purchase that never happened, or
    has not been approved. On 28 Sep 2026 a settings save posted rejected
    invoice 2821's entry: 5,700 g of 21k out of display inventory, 5,700 of
    sales and 102,600 of wages -- the year's weight profit fell 219 g -- and
    rejected 3123's, counting a re-entered sale twice (SETTINGS-001).
    """
    rows = (
        db.session.query(JournalEntry.id, JournalEntry.entry_number, JournalEntry.reference_type,
                         JournalEntry.reference_id, Invoice.status)
        .join(Invoice, Invoice.id == JournalEntry.reference_id)
        .filter(JournalEntry.reference_type.in_(['invoice', 'invoice_payments']))
        .filter(func.coalesce(JournalEntry.is_deleted, False) == False)  # noqa: E712
        .filter(func.coalesce(JournalEntry.is_posted, False) == True)  # noqa: E712
        .filter(func.coalesce(Invoice.is_posted, False) == False)  # noqa: E712
        .filter(_not_reversed())
        .all()
    )
    cash = _entry_cash([r.id for r in rows])
    return [
        Fact(POSTED_ENTRY_OF_UNPOSTED_INVOICE, f'journal_entry:{r.id}', cash.get(int(r.id), 0.0), {
            'entry_number': r.entry_number,
            'reference': f'{r.reference_type}:{r.reference_id}',
            'invoice_status': r.status,
            'cash_debit': cash.get(int(r.id), 0.0),
        })
        for r in rows
    ]


def check_gold_attribution_missing() -> list:
    """An approved gold payment to a supplier, declared for an invoice, that
    recorded no attribution.

    Above the historical boundary, the attribution row is the ONLY evidence of
    whom the gold paid, and the shared ceiling reads nothing else. The table held
    zero rows in production for its whole life because auto-approve skipped the
    hook -- so nothing could refuse a second 24.2 g payment against invoice
    3132's single 24.2 g obligation. PV-2026-01230 (voucher 4309) is the live
    instance on the 28 Sep snapshot.
    """
    from pricing.karat_service import convert_to_main_karat
    from services.gold_allocation_service import historical_attribution_boundary

    boundary = historical_attribution_boundary()
    rows = (
        db.session.query(Voucher.id, Voucher.voucher_number, Voucher.reference_id,
                         Voucher.supplier_id)
        .filter(Voucher.status == 'approved')
        .filter(Voucher.reference_type == 'invoice')
        .filter(Voucher.reference_id.isnot(None))
        .filter(Voucher.supplier_id.isnot(None))
        .filter(Voucher.id > boundary)
        .filter(exists().where(and_(
            VoucherAccountLine.voucher_id == Voucher.id,
            VoucherAccountLine.amount_type == 'gold',
            VoucherAccountLine.line_type == 'debit',
        )))
        .filter(~exists().where(VoucherInvoiceGoldAttribution.voucher_id == Voucher.id))
        .all()
    )
    facts = []
    for r in rows:
        lines = VoucherAccountLine.query.filter_by(
            voucher_id=r.id, amount_type='gold', line_type='debit').all()
        weight = round(sum(
            float(convert_to_main_karat(float(l.amount or 0.0), float(l.karat or 21.0)))
            for l in lines), 3)
        facts.append(Fact(GOLD_ATTRIBUTION_MISSING, f'voucher:{r.id}', weight, {
            'voucher_number': r.voucher_number,
            'invoice_id': r.reference_id,
            'supplier_id': r.supplier_id,
            'gold_main_karat': weight,
        }))
    return facts


def check_safebox_subledger_drift(threshold: float = DRIFT_THRESHOLD) -> list:
    """A safe box whose statement disagrees with its ledger.

    The one-sided class: a writer updates one record and not the other. Unpost
    wrote reversal movements and re-post restored only the ledger, so 92,385.00
    of posted receipts read as zero in the statements from May to September.
    Uses services/safebox_subledger.py, the same computation behind
    /safe-boxes/reconciliation.
    """
    boxes = SafeBox.query.with_entities(SafeBox.id, SafeBox.name).all()
    totals = subledger_totals_by_box([b.id for b in boxes])
    names = {int(b.id): b.name for b in boxes}
    facts = []
    for sid, t in totals.items():
        diff = round(float(t['sb_total']) - float(t['gl_total']), 2)
        if abs(diff) > threshold:
            facts.append(Fact(SAFEBOX_SUBLEDGER_DRIFT, f'safe_box:{sid}', diff, {
                'safe_box_name': names.get(sid),
                'statement_total': round(float(t['sb_total']), 2),
                'ledger_total': round(float(t['gl_total']), 2),
                'difference': diff,
            }))
    return facts


def check_safebox_gold_drift(threshold: float = GOLD_DRIFT_THRESHOLD) -> list:
    """A gold safe whose statement disagrees with its ledger, karat by karat.

    Gold was compared by nothing (SAFEBOX-001 S0): a supplier purchase posted
    at creation wrote no row for five months (9,528.5 g never in the display
    safe's statement) and a reservation's purchase wrote a row into it that no
    entry made (3,388.8 g). One fact per safe and karat, keyed
    'safe_box:<id>:<karat>k'; the metric is statement minus ledger, in grams.
    """
    names = {int(b.id): b.name for b in SafeBox.query.with_entities(SafeBox.id, SafeBox.name).all()}
    facts = []
    for sid, by_karat in gold_subledger_by_box().items():
        for karat, (statement, ledger) in by_karat.items():
            diff = round(statement - ledger, 3)
            if abs(diff) > threshold:
                facts.append(Fact(SAFEBOX_GOLD_DRIFT, f'safe_box:{sid}:{karat}', diff, {
                    'safe_box_name': names.get(sid),
                    'karat': karat,
                    'statement_grams': round(statement, 3),
                    'ledger_grams': round(ledger, 3),
                    'difference_grams': diff,
                }))
    return facts


CHECKS = {
    ORPHAN_POSTED_ENTRY: check_orphan_posted_entries,
    UNPOSTED_ENTRY_IN_LIMBO: check_unposted_entries_in_limbo,
    POSTED_ENTRY_OF_UNPOSTED_INVOICE: check_posted_entries_of_unposted_invoices,
    GOLD_ATTRIBUTION_MISSING: check_gold_attribution_missing,
    SAFEBOX_SUBLEDGER_DRIFT: check_safebox_subledger_drift,
    SAFEBOX_GOLD_DRIFT: check_safebox_gold_drift,
}


# ======================================================================
# Findings -- the one place their lifecycle is decided
# ======================================================================

def _detail(detail: dict) -> str:
    return json.dumps(detail, ensure_ascii=False, sort_keys=True, default=str)


def _moved(old: Optional[float], new: Optional[float]) -> bool:
    if old is None or new is None:
        return (old is None) != (new is None)
    return abs(float(new) - float(old)) > METRIC_EPSILON


def reconcile_findings(kind: str, source: str, facts, now: datetime = None) -> dict:
    """Bring the open findings of (kind, source) in line with what is true now.

    Opens a finding for each new subject, counts one that persists, reopens one
    whose magnitude moved (closing the old value, which keeps its history), and
    resolves one whose condition cleared. Touches no finding of any other kind
    or source -- STALE_SETTLEMENT belongs to the clearing scheduler.

    Returns the subject keys in each bucket. Caller commits.
    """
    now = now or datetime.utcnow()
    open_rows = {
        r.subject_key: r for r in ReconciliationFinding.query.filter_by(
            kind=kind, source=source, resolved_at=None).all()
        if r.subject_key
    }
    current = {f.subject_key: f for f in facts}
    result = {'opened': [], 'changed': [], 'persisting': [], 'resolved': []}

    for key, row in open_rows.items():
        if key not in current:
            row.resolved_at = now
            result['resolved'].append(key)

    moved = []
    for key, fact in current.items():
        row = open_rows.get(key)
        if row is None:
            continue
        if _moved(row.metric, fact.metric):
            row.resolved_at = now
            moved.append(fact)
            result['changed'].append(key)
        else:
            row.check_count = (row.check_count or 1) + 1
            row.detail = _detail(fact.detail)
            result['persisting'].append(key)

    # The partial unique index allows one OPEN row per (kind, subject): close
    # before reopening.
    db.session.flush()

    for fact in moved:
        db.session.add(ReconciliationFinding(
            kind=kind, source=source, subject_key=fact.subject_key,
            metric=fact.metric, detail=_detail(fact.detail), created_at=now))
    for key, fact in current.items():
        if key not in open_rows:
            db.session.add(ReconciliationFinding(
                kind=kind, source=source, subject_key=key,
                metric=fact.metric, detail=_detail(fact.detail), created_at=now))
            result['opened'].append(key)
    db.session.flush()
    return result


def record_event(kind: str, source: str, subject_key: str, metric=None,
                 detail: dict = None, now: datetime = None) -> Optional[ReconciliationFinding]:
    """Make a write visible: an open finding that a person resolves after review.

    For jobs that DO write and are allowed to -- the safe-box backfill -- so what
    they wrote is on record rather than silent. Idempotent per open subject.
    """
    existing = ReconciliationFinding.query.filter_by(
        kind=kind, source=source, subject_key=subject_key, resolved_at=None).first()
    if existing is not None:
        return existing
    row = ReconciliationFinding(kind=kind, source=source, subject_key=subject_key,
                                metric=metric, detail=_detail(detail or {}),
                                created_at=now or datetime.utcnow())
    db.session.add(row)
    db.session.flush()
    return row


class NothingToAccept(ValueError):
    pass


def accept_finding(kind: str, subject_key: str, *, by: str, reason: str,
                   now: datetime = None) -> ReconciliationFinding:
    """The owner accepts a finding that is true and stays true -- an entry they
    confirmed real though its document is gone (JE-00851, 3 Oct 2026).

    The fact must hold now; its open finding is opened if last night's run has
    not, and marked accepted. It stays open, counted every night, out of the
    news; if its magnitude moves, reconcile_findings closes it and opens a new
    one that nobody has accepted. Caller commits.
    """
    if not (reason or '').strip():
        raise ValueError('an accepted finding needs its reason')
    fact = next((f for f in CHECKS[kind]() if f.subject_key == subject_key), None)
    if fact is None:
        raise NothingToAccept(f'{kind} {subject_key} does not hold now')
    now = now or datetime.utcnow()
    row = ReconciliationFinding.query.filter_by(kind=kind, source=SOURCE, subject_key=subject_key,
                                                resolved_at=None).first()
    if row is None:
        row = ReconciliationFinding(kind=kind, source=SOURCE, subject_key=subject_key, metric=fact.metric,
                                    detail=_detail(fact.detail), created_at=now)
        db.session.add(row)
    row.accepted_at, row.accepted_by, row.accepted_reason = now, by, reason.strip()
    db.session.flush()
    return row


# ======================================================================
# Running
# ======================================================================

def collect_books_facts() -> dict:
    """Every check's facts, writing nothing at all. For the bench and the CLI."""
    return {kind: check() for kind, check in CHECKS.items()}


def run_books_invariants(now: datetime = None) -> dict:
    """Run every check and reconcile its findings. Caller commits.

    Returns {kind: {'opened', 'changed', 'persisting', 'resolved'}} -- the
    morning's news is 'opened' and 'changed'.
    """
    now = now or datetime.utcnow()
    return {
        kind: reconcile_findings(kind, SOURCE, facts, now)
        for kind, facts in collect_books_facts().items()
    }


# ======================================================================
# Reading
# ======================================================================

def _parse_detail(text):
    if not text:
        return None
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text  # STALE_SETTLEMENT and other older findings store plain text


def list_findings(*, status: str = 'open', kind: str = None, source: str = None,
                  since: datetime = None, limit: int = 500) -> list:
    """Findings as plain records, newest first.

    status: 'open' (default), 'accepted', 'resolved' or 'all'. An accepted
    finding is open but no longer news: 'open' leaves it out, 'accepted' lists
    it. since filters on created_at -- "what did last night's run open" is
    status='all', since=<last run>.
    """
    q = ReconciliationFinding.query
    if status == 'open':
        q = q.filter(ReconciliationFinding.resolved_at.is_(None), ReconciliationFinding.accepted_at.is_(None))
    elif status == 'accepted':
        q = q.filter(ReconciliationFinding.resolved_at.is_(None), ReconciliationFinding.accepted_at.isnot(None))
    elif status == 'resolved':
        q = q.filter(ReconciliationFinding.resolved_at.isnot(None))
    if kind:
        q = q.filter(ReconciliationFinding.kind == kind)
    if source:
        q = q.filter(ReconciliationFinding.source == source)
    if since is not None:
        q = q.filter(ReconciliationFinding.created_at >= since)
    rows = q.order_by(ReconciliationFinding.created_at.desc(),
                      ReconciliationFinding.id.desc()).limit(max(1, min(int(limit), 5000))).all()
    return [
        {
            'id': r.id,
            'kind': r.kind,
            'source': r.source,
            'subject_key': r.subject_key,
            'metric': r.metric,
            'detail': _parse_detail(r.detail),
            'check_count': r.check_count,
            'created_at': r.created_at.isoformat() if r.created_at else None,
            'resolved_at': r.resolved_at.isoformat() if r.resolved_at else None,
            'accepted_at': r.accepted_at.isoformat() if r.accepted_at else None,
            'accepted_by': r.accepted_by,
            'accepted_reason': r.accepted_reason,
        }
        for r in rows
    ]
