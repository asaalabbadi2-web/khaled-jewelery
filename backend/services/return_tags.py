"""A piece brought back by a sale return, and its label (ADR-097, the sale
return; the owner, 23 Nov 2026: «الزبون قد يتلف البطاقة» -- «جميع الاحتمالات
وارده»: the label taken off at the sale and kept or thrown away, or gone
with the customer, whole or torn).

The reader decides, not a person: each piece of a sale return says its label
-- or the return is refused:
1. its active tag read (an EPC of ours, this piece's, not stopped): `read` --
   it comes back with its label;
2. its printed number typed, or its printed code read (KJ-...): `printed` --
   the paper is this piece's, its tag not yet read: the first count by scan
   reads it (the nightly check says it until one does, or a new label is
   adopted);
3. «البطاقة مفقودة أو تالفة»: `missing` -- a label printed again, its job
   asked after the return is saved (ADR-097 law 1: saving never waits for
   printing); the old tag stopped when the new one is adopted (law 4);
4. a tag or a number of another piece, a stopped tag, an attempt's tag, one
   not ours: refused in its words -- a label not its own is never taken.
The sale stops no tag: a customer may bring it back whole.
"""
from __future__ import annotations

from models import Item, PieceReturnTag, db
from services.return_lines import ReturnRefused

READ, PRINTED, MISSING = 'read', 'printed', 'missing'
SALE_RETURN = 'مرتجع بيع'


def read_return_tags(invoice_type: str, items: list) -> list[dict]:
    """Each piece's label as the return says it -- or ReturnRefused. Read after
    sale_return_lines put each line's piece on it."""
    from services.pieces import TAG_ACTIVE, is_piece, piece_code, tag_state
    if invoice_type != SALE_RETURN:
        return []
    decisions = []
    for item in items or []:
        if not isinstance(item, dict) or not item.get('item_id'):
            continue
        piece = db.session.get(Item, int(item['item_id']))
        if not is_piece(piece):
            continue
        said = item.get('tag') if isinstance(item.get('tag'), dict) else {}
        code = piece.item_code
        if said.get('missing') is True:
            decisions.append({'item_id': piece.id, 'kind': MISSING, 'value': None, 'tag_id': None})
            continue
        value = str(said.get('value') or '').strip().upper()
        if not value:
            raise ReturnRefused('return_tag_required',
                                f'القطعة {code}: امسح بطاقتها، أو اختر «البطاقة مفقودة أو تالفة»', item_code=code)
        typed = piece_code(value)
        if typed is not None:
            if typed != code:
                raise ReturnRefused('return_tag_other_piece',
                                    f'البطاقة {typed} لقطعة أخرى، لا للقطعة {code}', item_code=code)
            decisions.append({'item_id': piece.id, 'kind': PRINTED, 'value': typed, 'tag_id': None})
            continue
        state = tag_state(value)
        if state['state'] == TAG_ACTIVE and state['item_id'] == piece.id:
            from services.pieces import active_tag
            decisions.append({'item_id': piece.id, 'kind': READ, 'value': value, 'tag_id': active_tag(piece).id})
            continue
        if state['item_id'] == piece.id:
            raise ReturnRefused('return_tag_not_active',
                                f'{state["message"]}: ليست بطاقة القطعة {code} المعتمدة — '
                                'اختر «البطاقة مفقودة أو تالفة» لتُطبع لها بطاقة', item_code=code)
        if state['item_id'] is not None:
            raise ReturnRefused('return_tag_other_piece',
                                f'الرقاقة لقطعة أخرى ({state["item_code"]})، لا للقطعة {code}', item_code=code)
        raise ReturnRefused('return_tag_unknown', f'{state["message"]}: ليست بطاقة القطعة {code}', item_code=code)
    return decisions


def record_return_tags(invoice, decisions: list[dict], *, by: str, now) -> list[PieceReturnTag]:
    """The decisions kept with the return, in its transaction."""
    rows = [PieceReturnTag(invoice_id=invoice.id, item_id=d['item_id'], kind=d['kind'], value=d['value'],
                           tag_id=d['tag_id'], created_at=now, created_by=by) for d in decisions]
    db.session.add_all(rows)
    db.session.flush()
    return rows


def unlabeled_returns() -> list[dict]:
    """The pieces a posted sale return brought back whose label is not
    settled: `missing` with no tag adopted since, `printed` with its tag not
    read by a count since nor a new one adopted -- while still in the stock."""
    from models import Invoice, PieceScan, PieceScanRead, PieceTag
    from services.pieces import GRAM, active_tag, piece_held
    found = []
    rows = (db.session.query(PieceReturnTag, Invoice)
            .join(Invoice, Invoice.id == PieceReturnTag.invoice_id)
            .filter(PieceReturnTag.kind.in_((MISSING, PRINTED)), Invoice.is_posted.is_(True),
                    db.func.coalesce(Invoice.status, '').notin_(('rejected', 'cancelled', 'ملغاة')))
            .order_by(PieceReturnTag.id).all())
    for row, invoice in rows:
        piece = db.session.get(Item, row.item_id)
        if piece_held(piece.id) <= GRAM:
            continue
        mounted_since = (PieceTag.query.filter(PieceTag.item_id == piece.id, PieceTag.mounted_at >= row.created_at)
                         .first() is not None)
        if mounted_since:
            continue
        if row.kind == PRINTED:
            tag = active_tag(piece)
            read_since = tag is not None and (
                db.session.query(PieceScanRead.id).join(PieceScan, PieceScan.id == PieceScanRead.scan_id)
                .filter(PieceScanRead.value == tag.value, PieceScan.started_at >= row.created_at).first()
                is not None)
            if read_since:
                continue
        found.append({'invoice_id': invoice.id, 'invoice_number': getattr(invoice, 'invoice_number', None),
                      'item_id': piece.id, 'item_code': piece.item_code, 'kind': row.kind,
                      'returned_at': row.created_at.isoformat()})
    return found
