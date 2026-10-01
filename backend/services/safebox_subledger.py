"""Safe-box sub-ledger vs general ledger — ONE computation, every reader.

A safe box has two records of its cash: the general ledger (the lines posted to
its account, which is what services/live_balances.safe_box_balance() reports as
the official balance), and its own statement of movements (SafeBoxTransaction).
They must agree. When they do not, a writer has updated one and not the other.

This module is the only place that decides which rows on each side count. It
was extracted from routes/safe_boxes.py::safe_boxes_reconciliation, where it
lived inside a route and so could only be used by someone who thought to call
that endpoint. services/books_invariants.py now runs the same computation every
night; the route calls it too, so the diagnostic screen and the nightly check
cannot disagree about what "drift" means.

Moved, not rewritten. The queries are the route's own, verbatim, and the route's
output was captured on a production snapshot before the move and compared
byte-for-byte after it.

Cash only, as the route always was. Gold is compared elsewhere.
"""
from __future__ import annotations

from sqlalchemy import Integer, and_, case, cast, func, or_
from sqlalchemy.orm import aliased

from models import JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, db

# Statement rows with no ledger counterpart by design.
DEFAULT_IGNORED_REF_TYPES = ('shift_closing_settlement', 'journal_entry')

# A difference no larger than this is agreement. The reconciliation screen's
# default and the nightly check's: one value, so they cannot disagree about
# what drift is. Policy (ADR-030) -- changing it needs no ADR, only this line.
DRIFT_THRESHOLD = 0.01

# Ledger entries with no statement counterpart by design (Fix 2b): manual
# journal entries move a safe-box account without a movement row.
MANUAL_JE_REFERENCE_TYPES = ('', 'manual', 'journal_entry')

KEYED_ROW_CAP = 200


def _sb_ref_type_norm():
    return func.lower(func.trim(func.coalesce(SafeBoxTransaction.ref_type, '')))


def _sb_ignore_filter(ignore_ref_types):
    ignore = list(ignore_ref_types or ())
    return _sb_ref_type_norm().notin_(ignore) if ignore else True


def _sb_signed():
    return func.sum(
        case(
            (SafeBoxTransaction.direction == 'in', func.coalesce(SafeBoxTransaction.amount_cash, 0.0)),
            else_=-func.coalesce(SafeBoxTransaction.amount_cash, 0.0),
        )
    )


def _gl_signed():
    return func.sum(
        func.coalesce(JournalEntryLine.cash_debit, 0.0) - func.coalesce(JournalEntryLine.cash_credit, 0.0)
    )


def _gl_counting_filters():
    """Which ledger lines count against a safe box's statement."""
    return (
        func.coalesce(JournalEntryLine.is_deleted, False) == False,  # noqa: E712
        func.coalesce(JournalEntry.is_deleted, False) == False,  # noqa: E712
        func.coalesce(JournalEntry.is_draft, False) == False,  # noqa: E712
        func.coalesce(JournalEntry.is_posted, True) == True,  # noqa: E712
        func.lower(func.trim(func.coalesce(JournalEntry.reference_type, ''))).notin_(
            list(MANUAL_JE_REFERENCE_TYPES)
        ),
    )


def subledger_totals_by_box(safe_ids, ignore_ref_types=DEFAULT_IGNORED_REF_TYPES) -> dict:
    """{safe_box_id: {'sb_total', 'gl_total'}} for every id in *safe_ids*.

    A box with no rows on a side reads 0.0 on that side, so every requested box
    is present in the result.
    """
    safe_ids = [int(s) for s in (safe_ids or [])]
    if not safe_ids:
        return {}

    sb_rows = (
        db.session.query(
            SafeBoxTransaction.safe_box_id.label('safe_box_id'),
            _sb_signed().label('sb_total'),
        )
        .filter(SafeBoxTransaction.safe_box_id.in_(safe_ids))
        .filter(_sb_ignore_filter(ignore_ref_types))
        .group_by(SafeBoxTransaction.safe_box_id)
        .all()
    )
    sb_totals = {int(r.safe_box_id): float(r.sb_total or 0.0) for r in sb_rows if r.safe_box_id is not None}

    gl_rows = (
        db.session.query(
            SafeBox.id.label('safe_box_id'),
            _gl_signed().label('gl_total'),
        )
        .select_from(JournalEntryLine)
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .join(SafeBox, SafeBox.account_id == JournalEntryLine.account_id)
        .filter(SafeBox.id.in_(safe_ids))
        .filter(*_gl_counting_filters())
        .group_by(SafeBox.id)
        .all()
    )
    gl_totals = {int(r.safe_box_id): float(r.gl_total or 0.0) for r in gl_rows if r.safe_box_id is not None}

    return {
        sid: {'sb_total': float(sb_totals.get(sid, 0.0)), 'gl_total': float(gl_totals.get(sid, 0.0))}
        for sid in safe_ids
    }


def subledger_keyed_breakdown(safe_box_id, ignore_ref_types=DEFAULT_IGNORED_REF_TYPES,
                              threshold=DRIFT_THRESHOLD) -> list:
    """Per (ref_type, ref_id) differences for ONE box, largest first, capped.

    Answers "which document is the drift in", once the totals say there is one.
    """
    sid = int(safe_box_id)
    gl_signed = _gl_signed()
    sb_signed = _sb_signed()
    sb_ref_type_norm = _sb_ref_type_norm()

    je_ref_type_raw = func.lower(func.trim(func.coalesce(JournalEntry.reference_type, '')))
    je_ref_type_norm = case((je_ref_type_raw == '', 'journal_entry'), else_=je_ref_type_raw)
    je_ref_id_norm = case(
        (or_(je_ref_type_raw == '', func.coalesce(JournalEntry.reference_id, 0) == 0), JournalEntry.id),
        else_=cast(JournalEntry.reference_id, Integer),
    )

    gl_keyed_rows = (
        db.session.query(
            je_ref_type_norm.label('ref_type'),
            je_ref_id_norm.label('ref_id'),
            gl_signed.label('gl_signed'),
        )
        .select_from(JournalEntryLine)
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .join(SafeBox, SafeBox.account_id == JournalEntryLine.account_id)
        .filter(SafeBox.id == sid)
        .filter(*_gl_counting_filters())
        .group_by(je_ref_type_norm, je_ref_id_norm)
        .all()
    )
    gl_keyed = {}
    for r in gl_keyed_rows:
        key = (str(r.ref_type or ''), int(r.ref_id or 0))
        gl_keyed[key] = float(r.gl_signed or 0.0)

    legacy_invoice_payment = and_(
        sb_ref_type_norm == 'invoice_payment',
        func.coalesce(SafeBoxTransaction.invoice_payment_id, 0) != 0,
        func.coalesce(SafeBoxTransaction.ref_id, 0) != 0,
        SafeBoxTransaction.ref_id != SafeBoxTransaction.invoice_payment_id,
    )
    sb_ref_type_key = case((legacy_invoice_payment, 'voucher'), else_=sb_ref_type_norm)
    sb_ref_id_key = case(
        (legacy_invoice_payment, cast(SafeBoxTransaction.ref_id, Integer)),
        else_=cast(SafeBoxTransaction.ref_id, Integer),
    )

    sb_keyed_rows = (
        db.session.query(
            sb_ref_type_key.label('ref_type'),
            sb_ref_id_key.label('ref_id'),
            sb_signed.label('sb_signed'),
        )
        .filter(SafeBoxTransaction.safe_box_id == sid)
        .filter(_sb_ignore_filter(ignore_ref_types))
        .group_by(sb_ref_type_key, sb_ref_id_key)
        .all()
    )
    sb_keyed = {}
    for r in sb_keyed_rows:
        key = (str(r.ref_type or ''), int(r.ref_id or 0))
        sb_keyed[key] = float(r.sb_signed or 0.0)

    keyed = []
    all_keys = set(sb_keyed.keys()) | set(gl_keyed.keys())
    for (rt, rid) in all_keys:
        sb_val = float(sb_keyed.get((rt, rid), 0.0))
        gl_val = float(gl_keyed.get((rt, rid), 0.0))
        d = sb_val - gl_val
        if abs(d) <= threshold:
            continue
        keyed.append({
            'ref_type': rt,
            'ref_id': rid,
            'sb_signed': round(sb_val, 2),
            'gl_signed': round(gl_val, 2),
            'diff': round(d, 2),
            'abs_diff': round(abs(d), 2),
        })

    keyed.sort(key=lambda r: r.get('abs_diff', 0.0), reverse=True)
    return keyed[:KEYED_ROW_CAP]


# ── Gold (SAFEBOX-001) ─────────────────────────────────────────────────────
# Per gold safe and karat: the statement rows against what the posted entries
# moved on the safe's account. Counting as for cash: a manual entry writes no
# statement row by design, so it counts on neither side -- its lines out of the
# ledger total, and a 'journal_entry' row mirroring it out of the statement.
# Policy (ADR-030): a smaller difference is agreement.
GOLD_DRIFT_THRESHOLD = 0.01
KARATS = ('18k', '21k', '22k', '24k')


def gold_subledger_by_box(safe_ids=None) -> dict:
    """{safe_box_id: {'21k': (statement_grams, ledger_grams), ...}} for every
    gold safe (or those in *safe_ids*)."""
    boxes = SafeBox.query.filter(SafeBox.safe_type == 'gold')
    if safe_ids is not None:
        boxes = boxes.filter(SafeBox.id.in_([int(s) for s in safe_ids]))
    ids = [b.id for b in boxes.with_entities(SafeBox.id).all()]
    if not ids:
        return {}

    signed = lambda col: func.sum(case((SafeBoxTransaction.direction == 'in', func.coalesce(col, 0.0)),
                                       else_=-func.coalesce(col, 0.0)))
    mirrored = aliased(JournalEntry)
    st_rows = (
        db.session.query(SafeBoxTransaction.safe_box_id,
                         *[signed(getattr(SafeBoxTransaction, f'weight_{k}')) for k in KARATS])
        .outerjoin(mirrored, and_(SafeBoxTransaction.ref_type == 'journal_entry',
                                  mirrored.id == SafeBoxTransaction.ref_id))
        .filter(SafeBoxTransaction.safe_box_id.in_(ids))
        .filter(_sb_ref_type_norm() != 'shift_closing_settlement')
        .filter(or_(SafeBoxTransaction.ref_type != 'journal_entry',
                    SafeBoxTransaction.ref_type.is_(None),
                    func.lower(func.trim(func.coalesce(mirrored.reference_type, ''))).notin_(
                        list(MANUAL_JE_REFERENCE_TYPES))))
        .group_by(SafeBoxTransaction.safe_box_id)
        .all()
    )
    gl_rows = (
        db.session.query(SafeBox.id,
                         *[func.sum(func.coalesce(getattr(JournalEntryLine, f'debit_{k}'), 0.0)
                                    - func.coalesce(getattr(JournalEntryLine, f'credit_{k}'), 0.0)) for k in KARATS])
        .select_from(JournalEntryLine)
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .join(SafeBox, SafeBox.account_id == JournalEntryLine.account_id)
        .filter(SafeBox.id.in_(ids))
        .filter(*_gl_counting_filters())
        .group_by(SafeBox.id)
        .all()
    )
    st = {int(r[0]): [float(v or 0.0) for v in r[1:]] for r in st_rows}
    gl = {int(r[0]): [float(v or 0.0) for v in r[1:]] for r in gl_rows}
    zero = [0.0] * len(KARATS)
    return {sid: {k: (st.get(sid, zero)[i], gl.get(sid, zero)[i]) for i, k in enumerate(KARATS)} for sid in ids}

