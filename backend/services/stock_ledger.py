"""The stock is the entry lines themselves (ADR-045 A1, the owner, 13 Oct 2026).

Location from the safe (SafeBox.stock_location), karat and grams from the
posted line, category from its allocation (StockLineAllocation). There is no
second ledger to drift: the karat totals are the books' by construction.

- allocate(): the one writer of an allocation, and its law -- a line's
  allocations for a karat never exceed its grams there, carry its sign, and
  only a stock safe's line is allocated.
- allocate_invoice(): an invoice allocates its stock lines by its items'
  categories, in its posting's transaction; a failure refuses the posting.
- stock_balances(): the one reader -- grams per (safe, karat, category), the
  unallocated rest under category None («بلا تصنيف»).
"""
from __future__ import annotations

from sqlalchemy import func

from models import (
    Invoice, InvoiceItem, Item, JournalEntry, JournalEntryLine, SafeBox, StockLineAllocation, db,
)

KARATS = (18, 21, 22, 24)
# A gram difference below this is no difference (the weight column's tolerance, stage-4 item 11c).
TOLERANCE = 0.005


class StockAllocationError(ValueError):
    """An allocation the law refuses -- the posting that asked for it is refused with it."""


def line_grams(line, karat: int) -> float:
    if karat not in KARATS:
        return 0.0
    return float(getattr(line, f'debit_{karat}k') or 0.0) - float(getattr(line, f'credit_{karat}k') or 0.0)


def _stock_safe_ids_by_account() -> dict:
    return {int(aid): int(sid) for sid, aid in db.session.query(SafeBox.id, SafeBox.account_id)
            .filter(SafeBox.stock_location.isnot(None)).all()}


def allocate(line, karat: int, category_id: int, grams: float, *, now, item_id=None, by=None):
    """Allocate grams of a stock line's karat to a category -- or refuse."""
    if int(line.account_id) not in _stock_safe_ids_by_account():
        raise StockAllocationError(f'السطر {line.id} ليس على خزينة مخزون')
    net = line_grams(line, int(karat))
    if abs(net) <= TOLERANCE:
        raise StockAllocationError(f'السطر {line.id} لا يحمل عيار {karat}')
    if grams * net < 0:
        raise StockAllocationError(f'التوزيع بعكس إشارة السطر {line.id}')
    taken = float(db.session.query(func.coalesce(func.sum(StockLineAllocation.grams), 0.0))
                  .filter(StockLineAllocation.journal_entry_line_id == line.id,
                          StockLineAllocation.karat == int(karat)).scalar() or 0.0)
    if abs(taken + grams) > abs(net) + TOLERANCE:
        raise StockAllocationError(
            f'التوزيع يتجاوز السطر {line.id} في عيار {karat}: {abs(taken + grams):.3f} من {abs(net):.3f}')
    row = StockLineAllocation(journal_entry_line_id=line.id, karat=int(karat), category_id=int(category_id),
                              item_id=item_id, grams=round(float(grams), 3), created_by=by,
                              created_at=now)
    db.session.add(row)
    db.session.flush()
    return row


def allocate_invoice(invoice: Invoice, *, now, by=None) -> list:
    """An invoice's stock lines, allocated by its items' categories.

    Idempotent: lines already allocated are left as they are. An invoice with
    no stock line allocates nothing. Items heavier than the stock lines of
    their karat are a disagreement between the invoice and its entry: refused.
    """
    safes = _stock_safe_ids_by_account()
    lines = (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice.id,
                     JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                     JournalEntryLine.account_id.in_(list(safes) or [-1]))
             .order_by(JournalEntryLine.id).all())
    if not lines:
        return []
    if StockLineAllocation.query.filter(
            StockLineAllocation.journal_entry_line_id.in_([l.id for l in lines])).first() is not None:
        return []

    by_karat = {}
    for ii in InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id).all():
        weight = float(ii.weight or 0.0)
        if weight <= 0:
            continue
        karat = int(round(float(ii.karat or 0.0)))
        category_id = ii.category_id
        if category_id is None and ii.item_id:
            item = db.session.get(Item, ii.item_id)
            category_id = getattr(item, 'category_id', None)
        by_karat.setdefault(karat, []).append((category_id, ii.item_id, weight))

    written = []
    for karat, items in by_karat.items():
        capacity = [(line, line_grams(line, karat)) for line in lines if abs(line_grams(line, karat)) > TOLERANCE]
        total = sum(abs(net) for _, net in capacity)
        weight = sum(w for _, _, w in items)
        if weight > total + TOLERANCE:
            raise StockAllocationError(
                f'أوزان أصناف الفاتورة {invoice.id} في عيار {karat} ({weight:.3f}) تتجاوز قيد مخزونها ({total:.3f})')
        left = [abs(net) for _, net in capacity]
        for category_id, item_id, w in items:
            if category_id is None:
                continue                      # unclassified: the line's rest
            for i, (line, net) in enumerate(capacity):
                if w <= TOLERANCE:
                    break
                take = min(w, left[i])
                if take <= TOLERANCE:
                    continue
                written.append(allocate(line, karat, category_id, take if net > 0 else -take,
                                        item_id=item_id, by=by, now=now))
                left[i] -= take
                w -= take
    return written


def stock_balances() -> list:
    """Grams per (safe, karat, category) -- the posted lines on stock safes,
    the unallocated rest under category None."""
    from accounting.balances import counted_line_filters
    from services.live_balances import live_balances_by_account_ids

    safes = _stock_safe_ids_by_account()
    if not safes:
        return []
    allocated = (db.session.query(JournalEntryLine.account_id, StockLineAllocation.karat,
                                  StockLineAllocation.category_id, func.sum(StockLineAllocation.grams))
                 .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
                 .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                 .filter(JournalEntryLine.account_id.in_(list(safes)), *counted_line_filters())
                 .group_by(JournalEntryLine.account_id, StockLineAllocation.karat,
                           StockLineAllocation.category_id).all())
    rows, classified = [], {}
    for account_id, karat, category_id, grams in allocated:
        grams = round(float(grams or 0.0), 3)
        classified[(int(account_id), int(karat))] = classified.get((int(account_id), int(karat)), 0.0) + grams
        if abs(grams) > TOLERANCE:
            rows.append({'safe_box_id': safes[int(account_id)], 'karat': int(karat),
                         'category_id': int(category_id), 'grams': grams})
    for account_id, balance in live_balances_by_account_ids(list(safes)).items():
        for karat in KARATS:
            rest = round(float(balance.get(f'{karat}k') or 0.0) - classified.get((int(account_id), karat), 0.0), 3)
            if abs(rest) > TOLERANCE:
                rows.append({'safe_box_id': safes[int(account_id)], 'karat': karat,
                             'category_id': None, 'grams': rest})
    return rows


UNCLASSIFIED = 'بلا تصنيف'


def _names(model, ids) -> dict:
    ids = {int(i) for i in ids if i is not None}
    if not ids:
        return {}
    return {int(r.id): r.name for r in model.query.filter(model.id.in_(ids)).all()}


def _location_filter(gold_type):
    """The old report's gold_type: 'scrap' is the scrap safes, 'new' the rest."""
    if gold_type == 'scrap':
        return SafeBox.stock_location == 'scrap'
    if gold_type == 'new':
        return SafeBox.stock_location != 'scrap'
    return None


def category_balances(*, safe_box_id=None, category_id=None, karat=None, group_by_karat=False,
                      gold_type=None) -> list:
    """The stock by (safe, category[, karat]) in the shape the category report
    reads (it read the retired tracker): grams signed, and at the main karat."""
    from models import Category
    from pricing.karat_service import convert_to_main_karat

    rows = stock_balances()
    if gold_type in ('scrap', 'new'):
        allowed = {sid for (sid,) in db.session.query(SafeBox.id).filter(_location_filter(gold_type)).all()}
        rows = [r for r in rows if r['safe_box_id'] in allowed]
    if safe_box_id:
        rows = [r for r in rows if r['safe_box_id'] == int(safe_box_id)]
    if category_id:
        rows = [r for r in rows if r['category_id'] == int(category_id)]
    if karat is not None:
        rows = [r for r in rows if abs(r['karat'] - float(karat)) < 0.001]

    grouped = {}
    for r in rows:
        key = (r['safe_box_id'], r['category_id'], r['karat'] if group_by_karat else None)
        grams, main = grouped.get(key, (0.0, 0.0))
        grouped[key] = (grams + r['grams'], main + convert_to_main_karat(r['grams'], r['karat']))
    safes = _names(SafeBox, [k[0] for k in grouped])
    categories = _names(Category, [k[1] for k in grouped])
    out = []
    for (sid, cid, k), (grams, main) in sorted(grouped.items(), key=lambda kv: (kv[0][0], kv[0][1] or 0, kv[0][2] or 0)):
        row = {'safe_box_id': sid, 'safe_box_name': safes.get(sid),
               'category_id': cid, 'category_name': categories.get(cid) if cid else UNCLASSIFIED,
               'weight_main_karat': round(main, 6), 'weight_grams_signed': round(grams, 6)}
        if group_by_karat:
            row['karat'] = float(k)
        out.append(row)
    return out


def stock_movements(*, safe_box_id=None, category_id=None, invoice_id=None, karat=None, gold_type=None,
                    start=None, end=None, limit=200) -> list:
    """The posted stock lines, newest first, each split into its allocations and
    its unallocated rest -- in the shape the category report reads."""
    from accounting.balances import counted_line_filters
    from models import Category
    from pricing.karat_service import convert_to_main_karat

    safes = _stock_safe_ids_by_account()
    if safe_box_id:
        safes = {a: s for a, s in safes.items() if s == int(safe_box_id)}
    if gold_type in ('scrap', 'new'):
        allowed = {sid for (sid,) in db.session.query(SafeBox.id).filter(_location_filter(gold_type)).all()}
        safes = {a: s for a, s in safes.items() if s in allowed}
    if not safes:
        return []
    q = (db.session.query(JournalEntryLine, JournalEntry)
         .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
         .filter(JournalEntryLine.account_id.in_(list(safes)), *counted_line_filters()))
    if invoice_id:
        q = q.filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == int(invoice_id))
    if start is not None:
        q = q.filter(JournalEntry.date >= start)
    if end is not None:
        q = q.filter(JournalEntry.date < end)
    q = q.order_by(JournalEntry.date.desc(), JournalEntryLine.id.desc())

    limit = max(1, min(int(limit or 200), 1000))
    out, invoices = [], {}
    for line, entry in q.yield_per(500):
        allocations = StockLineAllocation.query.filter_by(journal_entry_line_id=line.id).all()
        inv = None
        if entry.reference_type == 'invoice' and entry.reference_id:
            if entry.reference_id not in invoices:
                invoices[entry.reference_id] = db.session.get(Invoice, entry.reference_id)
            inv = invoices[entry.reference_id]
        for k in KARATS:
            if karat is not None and abs(k - float(karat)) >= 0.001:
                continue
            net = line_grams(line, k)
            if abs(net) <= TOLERANCE:
                continue
            parts = [(a.category_id, a.grams) for a in allocations if a.karat == k]
            rest = round(net - sum(g for _, g in parts), 3)
            if abs(rest) > TOLERANCE:
                parts.append((None, rest))
            for cid, grams in parts:
                if category_id and cid != int(category_id):
                    continue
                out.append({
                    'id': line.id,
                    'created_at': entry.date.isoformat() if entry.date else None,
                    'category_id': cid, 'safe_box_id': safes[int(line.account_id)],
                    'invoice_id': int(entry.reference_id) if entry.reference_type == 'invoice' and entry.reference_id else None,
                    'invoice_type': getattr(inv, 'invoice_type', None),
                    'gold_type': getattr(inv, 'gold_type', None),
                    'karat': float(k),
                    'weight_delta_grams': round(float(grams), 6),
                    'weight_delta_main_karat': round(convert_to_main_karat(float(grams), k), 6),
                    'created_by': entry.posted_by or entry.created_by,
                    'line_label': line.description or entry.description,
                    'note': entry.entry_number,
                })
        if len(out) >= limit:
            break
    out = out[:limit]
    safes_names = _names(SafeBox, {r['safe_box_id'] for r in out})
    categories = _names(Category, {r['category_id'] for r in out})
    for r in out:
        r['safe_box_name'] = safes_names.get(r['safe_box_id'])
        r['category_name'] = categories.get(r['category_id']) if r['category_id'] else UNCLASSIFIED
    return out
