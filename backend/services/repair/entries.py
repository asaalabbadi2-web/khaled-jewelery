"""Stage 4 corrects by entries -- one writer, one guard (the owner, 3 Oct 2026).

Every stage-4 correction is a posted entry: a reversal of a wrong entry, or a
new entry for one that is missing. Never an edit or a delete of a posted row.

The owner's rule (3 Oct 2026): the main cash box and the Riyadh bank were
corrected to match reality, and so were the clearing settlement accounts --
no correction touches them. What would have moved the main cash moves the
temporary cash box instead; what would have moved the Riyadh bank moves the
temporary bank account. And the main scrap safe (12 Oct 2026): what would
have moved it moves the reserve scrap safe.

- PROTECTED_ACCOUNT_NUMBERS: no line this module writes may name them;
- SUBSTITUTES: a reversal or re-post that would name one names its twin;
- a line on a safe box's account gets its statement row, so the safe's
  statement and ledger move together (SAFEBOX_SUBLEDGER_DRIFT and
  SAFEBOX_GOLD_DRIFT stay shut): its cash, and its gold karat by karat -- a
  row in for the karats that come in, a row out for those that go.

A reversal mirrors every debit/credit pair of the line -- cash, each karat and
the main-karat weight -- and negates its signed analytics, so the original and
its reversal net to zero on every column and in every report. A line carrying a value this module does not know how to mirror is
refused rather than half-reversed.
"""
from models import Account, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, db

REVERSAL = 'journal_entry_reversal'
# A statement row a stage-4 entry wrote: ref_id is the entry's id.
SAFE_ROW_REF_TYPE = 'stage4_correction'

# Policy (the owner, 3 Oct 2026): accounts that already match reality.
PROTECTED_ACCOUNT_NUMBERS = frozenset({
    '1100000',   # صندوق النقدية الرئيسي
    '1110000',   # ح/جاري بنك الرياض
    '340',       # فروقات تاريخية للمقاصة
    '1720',      # حساب وسيط تسوية الذهب
    '71720',     # حساب وسيط تسوية الذهب وزني
    '71310000',  # صندوق الكسر الرئيسي وزني (the owner, 12 Oct 2026)
})
SUBSTITUTES = {
    '1100000': '1100002',   # -> صندوق نقدية مؤقت
    '1110000': '1110001',   # -> حساب بنكي مؤقت
    '71310000': '71310002',  # -> صندوق الكسر الرئيسي احتياطي
}
KARATS = ('18k', '21k', '22k', '24k')

# Every debit/credit pair a line carries: (debit column, credit column).
PAIRS = (('cash_debit', 'cash_credit'),) + tuple(
    (f'debit_{k}', f'credit_{k}') for k in ('18k', '21k', '22k', '24k', 'weight'))
# Columns copied as they are.
COPIED = ('customer_id', 'supplier_id', 'weight_type', 'gold_price_snapshot', 'dimension_set_id')
# Signed (debit minus credit) analytics of the line, dimensions_service.compute_line_analytics:
# a mirror negates them, so the original and its reversal net to zero in the reports too.
SIGNED = ('analytic_amount_cash', 'analytic_weight_24k', 'analytic_weight_main')
# Columns whose sign this module does not know: a line carrying one is refused.
UNMIRRORED = ('gold_weight_equiv', 'gold_price_applied', 'gold_transaction_id')


class ProtectedAccount(ValueError):
    pass


class UnmirroredLine(ValueError):
    pass


def _ids_by_number(numbers) -> dict:
    rows = Account.query.with_entities(Account.account_number, Account.id).filter(
        Account.account_number.in_(list(numbers))).all()
    return {str(n): int(i) for n, i in rows}


def protected_account_ids() -> set:
    return set(_ids_by_number(PROTECTED_ACCOUNT_NUMBERS).values())


def substitute_ids() -> dict:
    """{protected account id: its temporary twin's id}."""
    ids = _ids_by_number(set(SUBSTITUTES) | set(SUBSTITUTES.values()))
    return {ids[a]: ids[b] for a, b in SUBSTITUTES.items() if a in ids and b in ids}


def _live_lines(entry, include_deleted=False):
    return [l for l in entry.lines if include_deleted or not getattr(l, 'is_deleted', False)]


def write_entry(*, date, description, reference_type, reference_id, reference_number=None, lines, by, now,
                prefix='COR', safe_rows=True, entry_type='عادي') -> JournalEntry:
    """A posted entry from *lines*: dicts of JournalEntryLine columns.

    Refuses a protected account. With safe_rows, a line on a cash safe box's
    account gets the statement row that moves with it. *now* is the run's
    clock, passed in (ADR-015): the posting time, not the entry's date.
    """
    from accounting.voucher_engine import _generate_journal_entry_number
    protected = protected_account_ids()
    hit = [l['account_id'] for l in lines if l['account_id'] in protected]
    if hit:
        raise ProtectedAccount(f'a correction may not touch accounts {sorted(set(hit))} (the owner, 3 Oct 2026)')
    for col_dr, col_cr in PAIRS:
        dr = round(sum(float(l.get(col_dr) or 0.0) for l in lines), 6)
        cr = round(sum(float(l.get(col_cr) or 0.0) for l in lines), 6)
        if abs(dr - cr) > 0.005:
            raise ValueError(f'unbalanced on {col_dr}/{col_cr}: {dr} vs {cr}')

    entry = JournalEntry(
        entry_number=_generate_journal_entry_number(prefix, entry_date=date), date=date,
        description=description[:200], entry_type=entry_type,
        reference_type=reference_type, reference_id=reference_id, reference_number=reference_number,
        is_posted=True, is_draft=False, posted_at=now, posted_by=by, created_by=by,
    )
    db.session.add(entry)
    db.session.flush()
    from dimensions_service import compute_line_analytics
    for spec in lines:
        line = JournalEntryLine(journal_entry_id=entry.id, **spec)
        if not any(c in spec for c in SIGNED):
            # A new line, as every writer computes its analytics (dual_system_helpers).
            line.analytic_amount_cash, line.analytic_weight_24k, line.analytic_weight_main = \
                compute_line_analytics(db.session, line)
        db.session.add(line)
    db.session.flush()
    if safe_rows:
        _write_safe_rows(entry, lines, by)
    return entry


def write_safe_rows(entry, lines, by, ref_type=None):
    """The statement row of each safe line of *entry* -- a gold safe's karats,
    a cash safe's cash. The stock count's entry writes its rows here too
    (ADR-045 C1), with its own ref_type."""
    return _write_safe_rows(entry, lines, by, ref_type=ref_type)


def _write_safe_rows(entry, lines, by, ref_type=None):
    accounts = {l['account_id'] for l in lines}
    safes = {int(s.account_id): s for s in SafeBox.query.filter(SafeBox.account_id.in_(list(accounts))).all()}
    for spec in lines:
        safe = safes.get(spec['account_id'])
        if safe is None:
            continue
        if float(spec.get('debit_weight') or 0.0) or float(spec.get('credit_weight') or 0.0):
            if not any(float(spec.get(f'{side}_{k}') or 0.0) for side in ('debit', 'credit') for k in KARATS):
                raise NotImplementedError(f'a main-karat weight with no karat on safe {safe.id}: no row to write')
        note = f'{entry.entry_number} — {entry.description}'[:500]
        net = float(spec.get('cash_debit') or 0.0) - float(spec.get('cash_credit') or 0.0)
        grams = {k: round(float(spec.get(f'debit_{k}') or 0.0) - float(spec.get(f'credit_{k}') or 0.0), 6)
                 for k in KARATS}
        for direction, sign in (('in', 1), ('out', -1)):
            cash = round(net * sign, 2) if net * sign >= 0.005 else 0.0
            weights = {f'weight_{k}': round(v * sign, 6) for k, v in grams.items() if v * sign >= 0.0005}
            if not cash and not weights:
                continue
            db.session.add(SafeBoxTransaction(
                safe_box_id=safe.id, ref_type=ref_type or SAFE_ROW_REF_TYPE, ref_id=entry.id, direction=direction,
                amount_cash=cash, created_at=entry.date, notes=note, created_by=by, **weights))
    db.session.flush()


def reversed_already(entry_id: int) -> bool:
    return db.session.query(JournalEntry.id).filter(
        JournalEntry.reference_type == REVERSAL, JournalEntry.reference_id == entry_id,
        JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False)).first() is not None


def mirrored_lines(entry, *, substitute=False, flip=True, include_deleted=False) -> list:
    """The entry's live lines as specs: mirrored (flip) or as they are, protected
    accounts replaced by their temporary twins when *substitute*. A deleted
    entry's lines are deleted with it: include_deleted reads them to re-post it."""
    subs = substitute_ids() if substitute else {}
    specs = []
    for line in _live_lines(entry, include_deleted):
        odd = [c for c in UNMIRRORED if getattr(line, c, None) not in (None, 0, 0.0)]
        if odd:
            raise UnmirroredLine(f'line {line.id} of {entry.entry_number} carries {odd}')
        spec = {c: getattr(line, c) for c in COPIED}
        spec['account_id'] = subs.get(line.account_id, line.account_id)
        for col_dr, col_cr in PAIRS:
            dr, cr = float(getattr(line, col_dr) or 0.0), float(getattr(line, col_cr) or 0.0)
            spec[col_dr], spec[col_cr] = (cr, dr) if flip else (dr, cr)
        for col in SIGNED:
            value = getattr(line, col)
            spec[col] = None if value is None else (-float(value) if flip else float(value))
        prefix = 'عكس' if flip else 'إعادة'
        spec['description'] = f'{prefix}: {line.description}'[:255] if line.description else prefix
        specs.append(spec)
    return specs


def reverse_entry(entry, *, by, reason, now, substitute=False, safe_rows=False, voucher=None) -> JournalEntry:
    """A posted reversal of *entry*, dated as the original: 'journal_entry_reversal'
    -> the original's id. The original is not touched.

    A cancelled voucher's entry is reversed as the app cancels one:
    'voucher_reversal' -> the voucher's id (journal_entry_guard holds to it)."""
    ref_type, ref_id = ('voucher_reversal', voucher.id) if voucher is not None else (REVERSAL, entry.id)
    return write_entry(
        date=entry.date, description=f'عكس القيد {entry.entry_number} — {reason}',
        reference_type=ref_type, reference_id=ref_id, reference_number=entry.entry_number,
        lines=mirrored_lines(entry, substitute=substitute), by=by, now=now, prefix='REV', safe_rows=safe_rows,
        entry_type=entry.entry_type or 'عادي')
