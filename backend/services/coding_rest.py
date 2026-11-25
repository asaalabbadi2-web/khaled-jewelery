"""«إقفال الباقي» (the owner, 25 Nov 2026: «ابنه»).

A receipt line or a batch of stock coded piece by piece leaves a rest: what
of its weight no piece took -- the scale's drift across many pieces, a few
hundredths of a gram. Left as it is, it lingers in the books under no piece
until the year's count; across hundreds of pieces it adds up. Closed here:

1. a rest above nothing and within Settings.coding_rest_tolerance (0.05 g);
   beyond it, a count's -- real gold, or a weight recorded wrong, is not a
   station's to write off;
2. once a line or a batch, its own entry, as a count's difference is written:
   its location's safe credited the grams, under its category and no piece,
   the count's shortage debited them -- by weight alone; from the wages'
   pools its wage at its pool's average with them; from the gold cost's day,
   valued as any shortage;
3. with a reason and a name; kept as written. Its rest reads nothing after:
   neither coded nor returned under no piece.
"""
from __future__ import annotations

from models import CodingRestClose, InvoiceItem, JournalEntry, JournalEntryLine, SafeBox, StockCoding, db
from services.pieces import (GRAM, PieceRefused, _receipt_stock_allocations, batch_rest, closed_rest,
                             coding_rest_tolerance, line_rest)

REFERENCE_TYPE = 'coding_rest'


def _place(source) -> tuple:
    """(safe, karat, category_id) the rest sits in."""
    if isinstance(source, StockCoding):
        return db.session.get(SafeBox, source.safe_box_id), int(source.karat), source.category_id
    karat = int(round(float(source.karat or 0)))
    rows = list(_receipt_stock_allocations(source, karat))
    row = rows[0] if rows else None
    if row is None:
        raise PieceRefused('rest_not_allocated', 'ذهب السطر غير موزَّع على تصنيفه في خزينة مخزون')
    line = db.session.get(JournalEntryLine, row.journal_entry_line_id)
    return SafeBox.query.filter_by(account_id=line.account_id).first(), karat, source.category_id


def close_rest(source, *, reason, by: str, now) -> CodingRestClose:
    """The rest of *source* (a receipt line or a batch) closed onto the count's
    shortage -- or PieceRefused, nothing written. The caller commits."""
    reason = str(reason or '').strip()
    if not reason:
        raise PieceRefused('rest_reason_required', 'اكتب سبب إقفال الباقي')
    source, what = _locked(source)
    rest = batch_rest(source) if isinstance(source, StockCoding) else line_rest(source)
    if abs(closed_rest(source)) > GRAM:
        raise PieceRefused('rest_closed_already', f'باقي {what} أُقفل من قبل')
    tolerance = coding_rest_tolerance()
    if rest <= GRAM:
        raise PieceRefused('rest_nothing', f'لا باقي في {what}')
    if rest > tolerance + GRAM:
        raise PieceRefused('rest_over_tolerance',
                           f'باقي {what} {rest:.3f} جم أكبر من المقبول إقفاله ({tolerance:.2f}): '
                           'رمّزه، أو يعالجه الجرد')
    return _write(source, rest, what=what, reason=reason, by=by, now=now)


def close_over(source, grams: float, *, reason, by: str, now) -> CodingRestClose:
    """A last piece heavier than the rest by the scale's drift (the owner, 25
    Nov 2026: «ماذا ان كان الفرق سالب؟» -- «ابنه»): the excess the count's
    surplus, so the piece registers whole -- within the tolerance, once a line
    or a batch. register_piece calls it in its own transaction, before the
    piece takes its grams."""
    reason = str(reason or '').strip()
    if not reason:
        raise PieceRefused('rest_reason_required', 'اكتب سبب زيادة الوزن')
    source, what = _locked(source)
    if abs(closed_rest(source)) > GRAM:
        raise PieceRefused('rest_closed_already', f'باقي {what} أُقفل من قبل')
    grams = round(float(grams), 3)
    if grams <= GRAM or grams > coding_rest_tolerance() + GRAM:
        raise PieceRefused('rest_over_tolerance', f'زيادة {grams:.3f} جم فوق المقبول: يعالجها تصحيح المصدر أو الجرد')
    return _write(source, -grams, what=what, reason=reason, by=by, now=now)


def _locked(source):
    if isinstance(source, StockCoding):
        source = StockCoding.query.with_for_update().get(source.id)
        return source, f'دفعة الترميز #{source.id}'
    source = InvoiceItem.query.with_for_update().get(source.id)
    return source, f'سطر الاستلام #{source.id}'


def _write(source, grams: float, *, what: str, reason: str, by: str, now) -> CodingRestClose:
    """The entry: *grams* above zero -- the rest out onto the shortage; below
    -- the excess in from the surplus; by weight alone, under the category and
    no piece, its wage with it from the pools' day, valued from the gold cost's."""
    from accounting.mappings import get_account_id_for_mapping
    from accounting.reference_number_service import generate_journal_entry_number
    from dimensions_service import compute_line_analytics
    from pricing.karat_service import convert_to_main_karat
    from services.inventory_accounting_service import ROLE_SHORTAGE, ROLE_SURPLUS, InventoryAccountingService
    from services.repair.entries import write_safe_rows
    from services.stock_ledger import allocate

    safe, karat, category_id = _place(source)
    if safe is None or safe.account_id is None:
        raise PieceRefused('rest_not_allocated', 'ذهب السطر ليس على خزينة مخزون')
    out = grams > 0
    try:
        count = InventoryAccountingService._weight_account(ROLE_SHORTAGE if out else ROLE_SURPLUS)
    except ValueError as missing:
        raise PieceRefused('rest_count_account_unmapped', str(missing)) from None

    size = abs(grams)
    description = (f'إقفال باقي {what} ({size:.3f} جم) — {reason}' if out
                   else f'زيادة وزن على {what} ({size:.3f} جم) — {reason}')[:200]
    entry = JournalEntry(entry_number=generate_journal_entry_number('JE', entry_date=now), date=now,
                         description=description, entry_type='عادي', reference_type=REFERENCE_TYPE,
                         is_posted=True, is_draft=False, posted_at=now, posted_by=by, created_by=by)
    db.session.add(entry)
    db.session.flush()
    main = round(convert_to_main_karat(size, karat), 6)
    safe_side, count_side = ('credit', 'debit') if out else ('debit', 'credit')
    specs = [dict(account_id=safe.account_id, description=description, **{f'{safe_side}_{karat}k': size},
                  **{f'{safe_side}_weight': main}),
             dict(account_id=count, description=description, **{f'{count_side}_{karat}k': size},
                  **{f'{count_side}_weight': main})]
    lines = []
    for spec in specs:
        line = JournalEntryLine(journal_entry_id=entry.id, **spec)
        line.analytic_amount_cash, line.analytic_weight_24k, line.analytic_weight_main = \
            compute_line_analytics(db.session, line)
        db.session.add(line)
        lines.append(line)
    db.session.flush()
    allocate(lines[0], karat, category_id, -grams, by=by, now=now)
    write_safe_rows(entry, specs, by, ref_type=REFERENCE_TYPE)

    closed = CodingRestClose(receipt_item_id=None if isinstance(source, StockCoding) else source.id,
                             coding_id=source.id if isinstance(source, StockCoding) else None,
                             grams=grams, journal_entry_id=entry.id, reason=reason[:200], closed_by=by, closed_at=now)
    db.session.add(closed)
    db.session.flush()
    entry.reference_id = closed.id

    # its wage with it, at its pool's average -- as a count's shortage or surplus (ADR-096)
    from services.wage_ledger import pools, value_the_count_wages, wage_pools_on
    if wage_pools_on(now):
        value_the_count_wages(entry, {(safe.id, karat): [(category_id, -grams)]}, pools(), now=now, by=by,
                              shortage_account_id=get_account_id_for_mapping('افتراضي', ROLE_SHORTAGE),
                              surplus_account_id=get_account_id_for_mapping('افتراضي', ROLE_SURPLUS))
    from services.gold_cost_postings import applies as gold_cost_applies, value_the_gold
    if gold_cost_applies(now):
        value_the_gold(entry.id, description='فرق باقي الترميز')
    db.session.flush()
    return closed
