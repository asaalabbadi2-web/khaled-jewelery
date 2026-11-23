"""A composite piece split into its parts (ADR-099; the owner, 23 Nov 2026).

A set with one tag -- a necklace, earrings, a ring, a bracelet -- and a
customer who buys two of them. The piece is split, each part weighed on its
own: a part of a category tracked by the piece is a piece born of it, with
its tag to print; a part of a category tracked by weight is its category's
grams. Then the parts are sold, or stay, as any.

The laws (each its test, tests/test_piece_split.py):
1. the parts' grams are the piece's, within Settings.piece_split_tolerance
   (0.05 g); the difference allowed is the split entry's own line on the
   count's shortage or surplus -- never hidden in a part;
2. karat and place are the piece's: never asked of a part;
3. no riyal moves: two lines on the location's safe, netting nothing but the
   difference (and, from the wages' pools, two on 1320 netting nothing);
4. one transaction: the entry, its allocations, the parts' pieces, their
   wages -- all or nothing (printing their labels is a job after it);
5. the piece's number and tag are never used again: every reader says
   «ليست في المخزون — فُكِّكت <day>» (services/pieces._last_exits);
6. each part on its own, two at least, each with its category;
7. the parts' wages are the piece's, by their weights, to the halala -- derived,
   never written (the owner, 23 Nov 2026: «الأجرة تشتق من القطعة المفككة»: a
   wage moved onto the part kept made the part sold look profitable, its
   seller's points with it); their stones its stones;
8. only a piece in stock, its wage known, its stones counted as gold; a
   piece born of a split split again by the manager alone (each split may
   leave 0.05 g on the shortage: chained, they add up);
9. a part is never sold before the split: the sale's law is unchanged.

Its entry is the stock's own record of the move (ADR-045 A1: the stock is
the entry lines) dated when it happened -- rewriting the piece's allocations
in place would move the categories' history back to the day it was received.
"""
from __future__ import annotations

from sqlalchemy import func

from models import (Category, Item, JournalEntry, JournalEntryLine, PieceSplit, PieceSplitPart, SafeBox, Settings,
                    StockLineAllocation, db)
from services.pieces import (GRAM, SPLIT_REFERENCE, STONES_PRICED, PieceRefused, is_piece, out_of_stock, piece_held,
                             piece_source, piece_wage, register_piece, stones_kind)

CENT = 0.005
MIN_PARTS = 2
DEFAULT_TOLERANCE = 0.05


def tolerance() -> float:
    value = getattr(Settings.query.first(), 'piece_split_tolerance', None)
    return float(DEFAULT_TOLERANCE if value is None else value)


def _place(piece: Item) -> tuple:
    """(safe, karat, grams): the one stock safe holding the piece, in the books."""
    from accounting.balances import counted_line_filters
    rows = (db.session.query(JournalEntryLine.account_id, StockLineAllocation.karat,
                             func.sum(StockLineAllocation.grams))
            .join(JournalEntryLine, JournalEntryLine.id == StockLineAllocation.journal_entry_line_id)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(StockLineAllocation.item_id == piece.id, *counted_line_filters())
            .group_by(JournalEntryLine.account_id, StockLineAllocation.karat).all())
    held = [(account, int(karat), round(float(grams), 3)) for account, karat, grams in rows if float(grams) > GRAM]
    if len(held) != 1:
        raise PieceRefused('split_piece_place', f'القطعة {piece.item_code} ليست في موقع واحد: لا تُفكَّك')
    account, karat, grams = held[0]
    safe = SafeBox.query.filter_by(account_id=account).first()
    return safe, karat, grams


def _number(value, what: str) -> float:
    try:
        return round(float(value), 3)
    except (TypeError, ValueError):
        raise PieceRefused('split_part_invalid', f'{what} غير مفهوم') from None


def _written(value) -> bool:
    return value is not None and not (isinstance(value, str) and not value.strip())


def read(piece: Item, parts, *, manager: bool = False) -> dict:
    """The split as it would be written -- the piece's place and wage, each
    part read (its category, grams, stones, its share of the wage by weight,
    the halala's rounding on the last), the difference -- or PieceRefused
    naming the first law it breaks. Nothing written. *manager*: the one
    splitting may split a piece born of a split."""
    if piece is None or not is_piece(piece):
        raise PieceRefused('split_not_a_piece', 'ليست قطعة: لا تُفكَّك')
    if getattr(piece, 'split_part_id', None) is not None and not manager:
        raise PieceRefused('split_of_a_split', f'القطعة {piece.item_code} وُلدت من تفكيك: '
                           'تفكيكها ثانيةً للمدير وحده')
    if PieceSplit.query.filter_by(piece_id=piece.id).first() is not None:
        raise PieceRefused('split_already', f'القطعة {piece.item_code} فُكِّكت من قبل')
    if piece_held(piece.id) <= GRAM:
        went = out_of_stock(piece)
        raise PieceRefused('split_piece_not_in_stock', f'القطعة {piece.item_code} '
                           f'{went["words"] if went else "ليست في المخزون"}: لا تُفكَّك')
    if stones_kind(piece_source(piece)) == STONES_PRICED:
        raise PieceRefused('split_stones_priced',
                           f'فصوص القطعة {piece.item_code} مسعّرة منفصلة: تفكيكها لم يُبنَ بعد (ADR-099)')
    wage = piece_wage(piece)
    if wage is None:
        raise PieceRefused('split_wage_unknown', f'القطعة {piece.item_code} لم تُستكمل فاتورة استلامها: '
                           'أجرتها غير معروفة فلا تُوزَّع')
    safe, karat, grams = _place(piece)
    parts = list(parts or [])
    if len(parts) < MIN_PARTS:
        raise PieceRefused('split_parts_too_few', 'التفكيك جزءان على الأقل، كل جزء منفردًا')

    read_parts = []
    for n, part in enumerate(parts, start=1):
        part = part if isinstance(part, dict) else {}
        try:
            category = db.session.get(Category, int(part.get('category_id')))
        except (TypeError, ValueError):
            category = None
        if category is None:
            raise PieceRefused('split_part_category', f'الجزء {n}: اختر تصنيفه')
        if category.is_active is False:
            raise PieceRefused('split_part_category', f'الجزء {n}: «{category.name}» موقوف')
        if category.is_scrap:
            raise PieceRefused('split_part_category', f'الجزء {n}: «{category.name}» تصنيف كسر، لا بضاعة معروضة')
        own_karat = str(category.karat or '').strip()
        if own_karat and own_karat.isdigit() and int(own_karat) != karat:
            raise PieceRefused('split_part_karat', f'الجزء {n}: «{category.name}» عيار {own_karat}، '
                               f'والقطعة عيار {karat}: الجزء يرث عيار قطعته')
        weight = _number(part.get('weight'), f'وزن الجزء {n}')
        stones = _number(part.get('stones_weight') or 0, f'فصوص الجزء {n}')
        if weight <= GRAM or stones < 0 or stones >= weight:
            raise PieceRefused('split_part_invalid', f'الجزء {n}: وزنه أكبر من صفر، وفصوصه أقل منه')
        if _written(part.get('wage')):
            raise PieceRefused('split_wage_written', f'الجزء {n}: أجرته تُشتق من أجرة القطعة بنسبة وزنه، '
                               'ولا تُكتب')
        read_parts.append({'category': category, 'weight': weight, 'stones_weight': stones, 'wage': None,
                           'piece': (category.tracking or 'weight') == 'piece'})

    total = round(sum(p['weight'] for p in read_parts), 3)
    difference = round(total - grams, 3)
    allowed = tolerance()
    if abs(difference) > allowed + GRAM:
        raise PieceRefused('split_weight_differs',
                           f'مجموع الأجزاء {total:.2f} جم ووزن القطعة {grams:.2f} جم: الفرق {abs(difference):.2f} '
                           f'أكبر من المقبول ({allowed:.2f}) — أعد الوزن، أو عالج الفرق بجرد أولًا')
    stones = round(float(piece.stones_weight or 0.0), 3)
    if abs(round(sum(p['stones_weight'] for p in read_parts), 3) - stones) > GRAM:
        raise PieceRefused('split_stones_differ',
                           f'فصوص الأجزاء لا تساوي فصوص القطعة ({stones:.2f} جم): وزّعها كلها')

    wage = round(float(wage), 2)
    left = wage
    for n, p in enumerate(read_parts):
        share = left if n == len(read_parts) - 1 else round(wage * p['weight'] / total, 2)
        p['wage'], left = share, round(left - share, 2)
    return {'piece': piece, 'safe': safe, 'karat': karat, 'grams': grams, 'stones_weight': stones, 'wage': wage,
            'parts': read_parts, 'total': total, 'difference': difference, 'tolerance': allowed}


def view(done: dict) -> dict:
    """read()'s answer for the screen."""
    piece = done['piece']
    return {'piece_id': piece.id, 'item_code': piece.item_code, 'karat': done['karat'], 'grams': done['grams'],
            'safe_box_id': done['safe'].id if done['safe'] else None,
            'safe_name': done['safe'].name if done['safe'] else None,
            'stones_weight': done['stones_weight'], 'wage': done['wage'], 'total': done['total'],
            'difference': done['difference'], 'tolerance': done['tolerance'],
            'parts': [{'category_id': p['category'].id, 'category_name': p['category'].name,
                       'tracking': 'piece' if p['piece'] else 'weight', 'weight': p['weight'],
                       'stones_weight': p['stones_weight'], 'wage': p['wage']} for p in done['parts']]}


def _side(karat: int, grams: float, debit: bool) -> dict:
    from pricing.karat_service import convert_to_main_karat
    main = round(convert_to_main_karat(grams, karat), 6)
    side = 'debit' if debit else 'credit'
    return {f'{side}_{karat}k': grams, f'{side}_weight': main}


def _count_account(role: str) -> int:
    from services.inventory_accounting_service import InventoryAccountingService
    try:
        return InventoryAccountingService._weight_account(role)
    except ValueError as missing:
        raise PieceRefused('split_count_account_unmapped', str(missing)) from None


def split_piece(piece_id: int, parts, *, reason, by: str, now, request_key=None, manager: bool = False) -> PieceSplit:
    """Split the piece into *parts* -- or PieceRefused, nothing written. The
    caller commits; a refusal is raised before anything is added."""
    from accounting.reference_number_service import generate_journal_entry_number
    from dimensions_service import compute_line_analytics
    from services.inventory_accounting_service import ROLE_SHORTAGE, ROLE_SURPLUS
    from services.repair.entries import write_safe_rows
    from services.stock_ledger import allocate

    key = str(request_key or '').strip() or None
    if key:
        done = PieceSplit.query.filter_by(request_key=key).first()
        if done is not None:
            return done
    reason = str(reason or '').strip()
    if not reason:
        raise PieceRefused('split_reason_required', 'اكتب سبب التفكيك')
    piece = Item.query.with_for_update().get(int(piece_id)) if piece_id else None
    done = read(piece, parts, manager=manager)
    karat, grams, safe, difference = done['karat'], done['grams'], done['safe'], done['difference']
    if safe is None or safe.account_id is None:
        raise PieceRefused('split_piece_place', f'القطعة {piece.item_code} ليست على خزينة مخزون')

    description = f'تفكيك قطعة {piece.item_code} — {reason}'[:200]
    entry = JournalEntry(entry_number=generate_journal_entry_number('JE', entry_date=now), date=now,
                         description=description, entry_type='عادي', reference_type=SPLIT_REFERENCE,
                         reference_id=piece.id, is_posted=True, is_draft=False, posted_at=now, posted_by=by, created_by=by)
    db.session.add(entry)
    db.session.flush()

    out_spec = dict(account_id=safe.account_id, description=description, **_side(karat, grams, False))
    in_spec = dict(account_id=safe.account_id, description=description, **_side(karat, done['total'], True))
    specs = [out_spec, in_spec]
    if difference < -GRAM:      # the parts weigh less: the rest is a count's shortage
        specs.append(dict(account_id=_count_account(ROLE_SHORTAGE), description=description,
                          **_side(karat, -difference, True)))
    elif difference > GRAM:     # more: a count's surplus
        specs.append(dict(account_id=_count_account(ROLE_SURPLUS), description=description,
                          **_side(karat, difference, False)))
    from services.wage_ledger import wage_account_id, wage_pools_on
    wage_account = wage_account_id() if wage_pools_on(now) else None
    if wage_account and done['wage'] > CENT:
        # the wage with its gold: out of the piece's own, into each part's (ADR-096)
        specs += [dict(account_id=wage_account, description=description, cash_credit=done['wage']),
                  dict(account_id=wage_account, description=description, cash_debit=done['wage'])]
    lines = []
    for spec in specs:
        line = JournalEntryLine(journal_entry_id=entry.id, **spec)
        line.analytic_amount_cash, line.analytic_weight_24k, line.analytic_weight_main = \
            compute_line_analytics(db.session, line)
        db.session.add(line)
        lines.append(line)
    db.session.flush()
    out_line, in_line = lines[0], lines[1]

    split = PieceSplit(piece_id=piece.id, journal_entry_id=entry.id, reason=reason[:200], difference=difference,
                       split_by=by, split_at=now, request_key=key)
    db.session.add(split)
    db.session.flush()

    allocate(out_line, karat, piece.category_id, -grams, item_id=piece.id, by=by, now=now)
    rows = []
    for position, p in enumerate(done['parts'], start=1):
        allocate(in_line, karat, p['category'].id, p['weight'], by=by, now=now)
        row = PieceSplitPart(split_id=split.id, position=position, category_id=p['category'].id,
                             weight=p['weight'], stones_weight=p['stones_weight'], wage=p['wage'])
        db.session.add(row)
        rows.append((row, p))
    db.session.flush()
    write_safe_rows(entry, specs, by, ref_type=SPLIT_REFERENCE)

    born = {}
    for row, p in rows:
        if p['piece']:
            born[row.id] = register_piece(row, weight=p['weight'], stones_weight=p['stones_weight'],
                                          by=by, now=now).id
    if wage_account and done['wage'] > CENT:
        from services.wage_ledger import allocate as allocate_wage
        wage_out, wage_in = lines[-2], lines[-1]
        allocate_wage(wage_out, karat=karat, category_id=piece.category_id, riyals=-done['wage'], item_id=piece.id,
                      now=now, by=by)
        for row, p in rows:
            if p['wage'] > CENT:
                allocate_wage(wage_in, karat=karat, category_id=p['category'].id, riyals=p['wage'],
                              item_id=born.get(row.id), now=now, by=by)
    from services.gold_cost_postings import applies as gold_cost_applies, value_the_gold
    if gold_cost_applies(now) and abs(difference) > GRAM:
        value_the_gold(entry.id, description='فرق تفكيك قطعة')
    db.session.flush()
    return split


def split_view(split: PieceSplit) -> dict:
    """A split as its screens show it: the piece, who and why, its parts --
    each a piece's number, or its category's grams."""
    piece = db.session.get(Item, split.piece_id)
    entry = db.session.get(JournalEntry, split.journal_entry_id)
    born = {i.split_part_id: i for i in Item.query.filter(Item.split_part_id.in_([p.id for p in split.parts]))}
    return {'id': split.id, 'piece_id': piece.id, 'item_code': piece.item_code, 'reason': split.reason,
            'difference': round(float(split.difference or 0.0), 3), 'split_by': split.split_by,
            'split_at': split.split_at.isoformat(), 'entry_number': entry.entry_number if entry else None,
            'parts': [{'id': p.id, 'category_id': p.category_id,
                       'category_name': getattr(db.session.get(Category, p.category_id), 'name', None),
                       'weight': round(float(p.weight), 3), 'stones_weight': round(float(p.stones_weight or 0), 3),
                       'wage': round(float(p.wage), 2),
                       'piece_id': born[p.id].id if p.id in born else None,
                       'item_code': born[p.id].item_code if p.id in born else None} for p in split.parts]}


def splits_list(*, limit: int = 200) -> list[dict]:
    """«سجلّ التفكيك» (the owner, 23 Nov 2026): every split, the newest first --
    who, when, why, into what -- for a manager's review: a split on paper,
    the set left whole in its showcase, shows only here and in a count by weight."""
    from services.piece_scan import name_of
    rows = PieceSplit.query.order_by(PieceSplit.split_at.desc(), PieceSplit.id.desc()).limit(int(limit)).all()
    out = []
    for split in rows:
        view = split_view(split)
        piece = db.session.get(Item, split.piece_id)
        view.update(split_by_name=name_of(split.split_by), weight=round(float(piece.weight or 0.0), 3),
                    category_name=getattr(db.session.get(Category, piece.category_id), 'name', None))
        out.append(view)
    return out
