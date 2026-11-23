"""A count of a location's pieces by their tags (ADR-085 ت2; the owner, 21 Nov 2026).

For reading: no entry, no stock moved, no piece's place changed -- the
corrections have their own ways (a transfer voucher, a count by weight).

One moment of reference, the start (ADR-085 ت2 §1, §7): the pieces in the
location then are its expected rows; where every other piece in stock was
then is its `places`. Each value read is judged by that snapshot, while the
scan is open and at its finish alike -- what the coder sees is what is kept.
The tags' registry alone is read live until the finish: an attempt settled
from the reader during the scan changes its read's verdict on purpose. At
the finish the verdicts are frozen, and what moved in the books since the
start is said apart («تحرّكت أثناء الجرد»).

A scan's scope (the owner, 21 Nov 2026): every piece in its location, or one
section's, or one category's -- the reader reads every tag near it whatever
it is, so a piece of the location outside the scope, or of another location
outside it, is said «من نطاق آخر»: not found, not an alert, never missing.
A piece of the scope elsewhere is «في غير موقعها»; one out of the stock is
«خرجت» whatever its scope -- its tag in the shop is the books' question.

A scan is complete -- may be finished, its pieces not read said missing --
when the last Settings.scan_quiet_presses presses read no new value, or the
reader's button was held Settings.scan_quiet_seconds since the last new one.
Complete is the least before finishing, not a proof that every piece was
read; nothing finishes by itself, and a press after the quiet goes on.
"""
from __future__ import annotations

import re

from models import (Category, Item, ItemSection, PieceScan, PieceScanEvent, PieceScanExpected, PieceScanRead,
                    SafeBox, Settings, db)
from services.pieces import (EXITS, _last_exits, active_tag, out_of_stock, stock_pieces, tag_state)

KINDS = {'opening': 'جرد فتح', 'closing': 'جرد إغلاق', 'check': 'تحقّق'}
NOT_A_SCAN_LOCATION = ('deposit',)          # an office's deposit is not the shop's stock (ADR-052)
EVENTS_A_BATCH = 2000
PRINTED = re.compile(r'^KJ-\d{6,}$')

# A read's verdicts, and an expected piece's (ADR-085 ت2 §2).
FOUND, ELSEWHERE, OUT, STOPPED, UNCONFIRMED, UNKNOWN, OTHER_SCOPE = (
    'found', 'elsewhere', 'out', 'stopped', 'unconfirmed', 'unknown', 'other_scope')
MISSING, UNREAD, UNTAGGED, MOVED = 'missing', 'unread', 'untagged', 'moved'
WORDS = {
    FOUND: 'موجودة', ELSEWHERE: 'في غير موقعها', OUT: 'خرجت من المخزون', STOPPED: 'بطاقة ملغاة',
    UNCONFIRMED: 'محاولة لم تُعتمد', UNKNOWN: 'ليست من رموزنا', OTHER_SCOPE: 'من نطاق آخر', MISSING: 'ناقصة',
    UNREAD: 'لم تُقرأ (مسح غير مكتمل)', UNTAGGED: 'بلا رقاقة معتمدة', MOVED: 'تحرّكت أثناء الجرد',
}


class ScanRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


# ── the snapshot ─────────────────────────────────────────────────────────────

def _places_now() -> dict:
    """{piece id: its safe's id, or None when no one safe holds it} -- every
    piece in stock, in one reading of the books."""
    return {piece.id: (safe.id if safe is not None else None) for piece, safe in stock_pieces()}


def scan_locations() -> list:
    """The locations a scan counts: the shop's stock safes, not an office's deposit."""
    return (SafeBox.query.filter(SafeBox.is_active.is_(True), SafeBox.stock_location.isnot(None),
                                 SafeBox.stock_location.notin_(NOT_A_SCAN_LOCATION))
            .order_by(SafeBox.id).all())


def _scope(section_id, category_id):
    """(section, category) of a scan: one at most, each one that is."""
    def read(raw, model, code, words):
        if raw in (None, '', 0, '0'):
            return None
        try:
            row = db.session.get(model, int(raw))
        except (TypeError, ValueError):
            row = None
        if row is None:
            raise ScanRefused(code, words)
        return row
    section = read(section_id, ItemSection, 'scan_section_not_found', 'القسم غير موجود')
    category = read(category_id, Category, 'scan_category_not_found', 'التصنيف غير موجود')
    if section is not None and category is not None:
        raise ScanRefused('scan_scope_one', 'نطاق الجرد قسم أو تصنيف، لا الاثنان')
    return section, category


def _in_scope(scan: PieceScan, piece: Item) -> bool:
    if scan.category_id is not None:
        return piece.category_id == scan.category_id
    if scan.section_id is not None:
        category = db.session.get(Category, piece.category_id) if piece.category_id else None
        return category is not None and category.section_id == scan.section_id
    return True


def start_scan(*, safe_box_id, kind, by: str, now, section_id=None, category_id=None) -> PieceScan:
    """A scan opened: its location's pieces of its scope and every other
    piece's place, as the books hold them now -- or ScanRefused."""
    if kind not in KINDS:
        raise ScanRefused('scan_kind_invalid', 'نوع الجرد: فتح، أو إغلاق، أو تحقّق')
    section, category = _scope(section_id, category_id)
    try:
        safe = db.session.get(SafeBox, int(safe_box_id))
    except (TypeError, ValueError):
        safe = None
    if safe is None or safe not in scan_locations():
        raise ScanRefused('scan_location_invalid', 'الجرد بالمسح لموقع مخزون من مواقع المحل، لا لوديعة مكتب')
    places = _places_now()
    scan = PieceScan(safe_box_id=safe.id, kind=kind, status='open', started_by=by, started_at=now, presses=0,
                     section_id=getattr(section, 'id', None), category_id=getattr(category, 'id', None), places={})
    here = {i for i, p in places.items() if p == safe.id}
    pieces = {p.id: p for p in Item.query.filter(Item.id.in_(here))} if here else {}
    expected = {i for i in here if _in_scope(scan, pieces[i])}
    # the snapshot's other half: every piece in stock not expected -- here outside the scope, or elsewhere
    scan.places = {str(i): p for i, p in places.items() if i not in expected}
    db.session.add(scan)
    db.session.flush()
    for item_id in sorted(expected):
        db.session.add(PieceScanExpected(scan_id=scan.id, item_id=item_id))
    db.session.flush()
    return scan


def _expected_ids(scan: PieceScan) -> set:
    return {e.item_id for e in PieceScanExpected.query.filter_by(scan_id=scan.id)}


def _safe_name(safe_id) -> str:
    safe = db.session.get(SafeBox, safe_id) if safe_id else None
    return safe.name if safe is not None else 'أكثر من موقع'


# ── a value judged by the snapshot ───────────────────────────────────────────

def judge(scan: PieceScan, value: str, *, expected: set | None = None) -> dict:
    """{verdict, item_id, words, attempt_id, unsettled} of a value read, by the
    scan's snapshot -- its location's pieces and every other's place at the
    start -- and the tags' registry as it stands."""
    value = str(value or '').strip().upper()
    expected = _expected_ids(scan) if expected is None else expected
    said = {'verdict': UNKNOWN, 'item_id': None, 'words': None, 'attempt_id': None, 'unsettled': False}
    if PRINTED.match(value):
        piece = Item.query.filter_by(item_code=value).first()
        if piece is None:
            return {**said, 'words': f'رمز مطبوع لا قطعة له {value}'}
        return _placed(scan, piece, expected, how='بالرمز المطبوع')
    state = tag_state(value)
    if state['state'] == 'active':
        return _placed(scan, db.session.get(Item, state['item_id']), expected, how=None)
    if state['state'] == 'stopped':
        piece = db.session.get(Item, state['item_id'])
        tag = active_tag(piece)
        now_words = f' — المعتمدة الجيل {tag.generation:04d}' if tag is not None else ' — ولا رقاقة معتمدة لها'
        return {**said, 'verdict': STOPPED, 'item_id': piece.id, 'words': f'{state["message"]}{now_words}'}
    if state['state'] == 'unconfirmed':
        return {**said, 'verdict': UNCONFIRMED, 'item_id': state['item_id'], 'words': state['message'],
                'attempt_id': state.get('attempt_id'), 'unsettled': bool(state.get('unsettled'))}
    return {**said, 'words': state['message']}


def _placed(scan, piece, expected, *, how) -> dict:
    said = {'item_id': piece.id, 'attempt_id': None, 'unsettled': False}
    suffix = f' ({how})' if how else ''
    if piece.id in expected:
        return {**said, 'verdict': FOUND, 'words': f'{piece.item_code}{suffix}'}
    place = (scan.places or {}).get(str(piece.id), 'out')
    if place != 'out' and not _in_scope(scan, piece):
        return {**said, 'verdict': OTHER_SCOPE, 'words': f'{piece.item_code} — ليست من نطاق هذا الجرد{suffix}'}
    if place != 'out':
        return {**said, 'verdict': ELSEWHERE,
                'words': f'{piece.item_code} — مكانها في الدفاتر «{_safe_name(place)}»{suffix}'}
    out = out_of_stock(piece) or {'words': 'ليست في المخزون'}
    return {**said, 'verdict': OUT, 'words': f'{piece.item_code} — {out["words"]}{suffix}'}


# ── the reads, as they come ──────────────────────────────────────────────────

def _open_scan(scan_id) -> PieceScan:
    scan = PieceScan.query.with_for_update().get(int(scan_id))
    if scan is None:
        raise ScanRefused('scan_not_found', 'جلسة الجرد غير موجودة')
    if scan.status != 'open':
        raise ScanRefused('scan_not_open', 'جلسة الجرد منتهية أو متروكة: لا تُقرأ فيها رقاقات')
    return scan


def take_reads(scan_id, *, batch_key, events, now) -> PieceScan:
    """A batch of what the reader sent: [{kind: read|button, value, press,
    ms}] -- recorded once by its key (a batch sent again changes nothing),
    each new value a read of the scan."""
    scan = _open_scan(scan_id)
    key = str(batch_key or '').strip()
    if not key or len(key) > 64:
        raise ScanRefused('scan_batch_key', 'مفتاح الدفعة مطلوب، 64 حرفًا على الأكثر')
    if PieceScanEvent.query.filter_by(scan_id=scan.id, batch_key=key).first() is not None:
        return scan
    if not isinstance(events, list) or len(events) > EVENTS_A_BATCH:
        raise ScanRefused('scan_events_invalid', f'الدفعة قائمة من {EVENTS_A_BATCH} قراءة على الأكثر')
    taken = []
    for event in events:
        try:
            kind = str(event.get('kind') or 'read')
            press, ms = int(event['press']), int(event['ms'])
        except (AttributeError, KeyError, TypeError, ValueError):
            raise ScanRefused('scan_events_invalid', 'كل قراءة لها ضغطتها ووقتها') from None
        value = ''.join(str(event.get('value') or '').split()).upper() or None
        if kind not in ('read', 'button') or press < 1 or ms < 0 or (kind == 'read' and not value) \
                or (value is not None and len(value) > 40):
            raise ScanRefused('scan_events_invalid', 'قراءة غير مفهومة')
        taken.append((kind, value if kind == 'read' else None, press, ms))
    seen = {r.value for r in PieceScanRead.query.filter_by(scan_id=scan.id)}
    for kind, value, press, ms in taken:
        db.session.add(PieceScanEvent(scan_id=scan.id, batch_key=key, kind=kind, value=value, press=press,
                                      at_ms=ms, received_at=now))
        scan.presses = max(scan.presses or 0, press)
        if kind == 'read' and value not in seen:
            seen.add(value)
            db.session.add(PieceScanRead(scan_id=scan.id, value=value, first_press=press, first_ms=ms))
    db.session.flush()
    return scan


def completeness(scan: PieceScan) -> dict:
    """{complete, quiet_presses, quiet_seconds, all_found}: how long since the
    last new value -- in presses, and in the time the button was held: a pause
    between two presses is not counted -- or every piece expected found: then
    none is left to wait for (the owner's rehearsal, 23 Nov 2026: «تظهر جميع
    القطع من أول مسحة وزر إنهاء الجرد لا زال غير مفعّل»)."""
    settings = Settings.query.first()
    want_presses = int(getattr(settings, 'scan_quiet_presses', None) or 3)
    want_seconds = float(getattr(settings, 'scan_quiet_seconds', None) or 3.0)
    reads = PieceScanRead.query.filter_by(scan_id=scan.id).all()
    if not reads:
        return {'complete': False, 'quiet_presses': 0, 'quiet_seconds': 0.0, 'all_found': False,
                'needs_presses': want_presses, 'needs_seconds': want_seconds}
    # judged as the screen sees them: an open scan's verdicts are not kept until its finish
    expected = _expected_ids(scan)
    if scan.status == 'open':
        found = set()
        for r in reads:
            said = judge(scan, r.value, expected=expected)
            if said['verdict'] == FOUND:
                found.add(said['item_id'])
    else:
        found = {r.item_id for r in reads if r.verdict == FOUND}
    all_found = bool(expected) and expected <= found
    newest = max(reads, key=lambda r: (r.first_press, r.first_ms))
    quiet_presses = max((scan.presses or 0) - newest.first_press, 0)
    # held, not waited: each press's own span from the newest value on -- the
    # time between two presses is no reading (a press, a pause, is not a scan)
    spans = (db.session.query(PieceScanEvent.press, db.func.min(PieceScanEvent.at_ms), db.func.max(PieceScanEvent.at_ms))
             .filter(PieceScanEvent.scan_id == scan.id, PieceScanEvent.press >= newest.first_press)
             .group_by(PieceScanEvent.press).all())
    held_ms = sum(max(last - (newest.first_ms if press == newest.first_press else first), 0)
                  for press, first, last in spans)
    quiet_seconds = held_ms / 1000.0
    return {'complete': all_found or quiet_presses >= want_presses or quiet_seconds >= want_seconds,
            'quiet_presses': quiet_presses, 'quiet_seconds': round(quiet_seconds, 1), 'all_found': all_found,
            'needs_presses': want_presses, 'needs_seconds': want_seconds}


# ── the finish ───────────────────────────────────────────────────────────────

def _moved(item_id, then, now_places, exits) -> str | None:
    """What happened to a piece between the start and now, or None."""
    now = now_places.get(item_id, 'out')
    if now == then:
        return None
    if now == 'out':
        exit_ = exits.get(item_id)
        return f'{EXITS.get(exit_[1], "خرجت") if exit_ else "خرجت"} أثناء الجرد'
    return f'نُقلت أثناء الجرد إلى «{_safe_name(now)}»'


def finish_scan(scan_id, *, by: str, now, early=False, reason=None) -> PieceScan:
    """Its verdicts frozen: each read's by the snapshot, each expected piece's
    -- found, missing (complete only), unread, untagged, moved -- and what
    moved since the start. Refused before complete, unless finished early
    with its reason, said so."""
    scan = _open_scan(scan_id)
    complete = completeness(scan)['complete']
    if not complete and not early:
        raise ScanRefused('scan_not_complete',
                          'لم يكتمل المسح: تابع الضغط حتى لا تظهر رقاقة جديدة، أو أنهِه قبل اكتماله بسبب')
    if not complete and not str(reason or '').strip():
        raise ScanRefused('scan_early_reason', 'إنهاء الجرد قبل اكتمال المسح يحتاج سببه')
    expected = _expected_ids(scan)
    now_places, exits = _places_now(), {}
    involved = set(expected)
    reads = PieceScanRead.query.filter_by(scan_id=scan.id).all()
    for read in reads:
        said = judge(scan, read.value, expected=expected)
        read.verdict, read.item_id, read.words = said['verdict'], said['item_id'], said['words']
        if read.item_id is not None and said['verdict'] in (FOUND, ELSEWHERE, OUT):
            involved.add(read.item_id)
    exits = _last_exits(involved)
    found = {r.item_id for r in reads if r.verdict == FOUND}
    for read in reads:
        if read.verdict in (FOUND, ELSEWHERE, OUT):
            then = scan.safe_box_id if read.item_id in expected else (scan.places or {}).get(str(read.item_id), 'out')
            read.moved = _moved(read.item_id, then, now_places, exits)
    for row in PieceScanExpected.query.filter_by(scan_id=scan.id):
        row.moved = _moved(row.item_id, scan.safe_box_id, now_places, exits)
        if row.item_id in found:
            row.verdict = FOUND
        elif row.moved:
            row.verdict = MOVED
        elif active_tag(db.session.get(Item, row.item_id)) is None:
            row.verdict = UNTAGGED
        else:
            row.verdict = MISSING if complete else UNREAD
    scan.status, scan.finished_by, scan.finished_at = 'finished', by, now
    scan.complete = complete
    scan.early_reason = None if complete else str(reason).strip()[:200]
    db.session.flush()
    return scan


def settle_read(scan_id, read_id, *, by: str, clock, commit) -> PieceScan:
    """A read whose tag is an attempt's whose end was not known: settled by
    that very value (ADR-085 ت2 §3) -- the attempt the server finds for it, the
    value the reader read; written on the read, by whom and when. An open
    scan only: a finished one is as it was."""
    from models import PrintAttempt
    from services.label_printing import resolve_attempt
    scan = _open_scan(scan_id)
    read = db.session.get(PieceScanRead, int(read_id))
    if read is None or read.scan_id != scan.id:
        raise ScanRefused('scan_read_not_found', 'القراءة ليست من هذا الجرد')
    said = judge(scan, read.value)
    if said['verdict'] != UNCONFIRMED or not said['unsettled'] or not said['attempt_id']:
        raise ScanRefused('scan_read_not_unsettled', 'هذه القراءة ليست رقاقة محاولة لم تُحسم')
    attempt = db.session.get(PrintAttempt, said['attempt_id'])
    resolve_attempt(attempt, read_value=read.value, by=by, clock=clock, commit=lambda: None)
    read.resolved_attempt_id, read.resolved_by, read.resolved_at = attempt.id, by, clock()
    db.session.flush()
    commit()
    return scan


def abandon_scan(scan_id, *, by: str, now) -> PieceScan:
    """A scan left: nothing judged, kept in the log as left."""
    scan = _open_scan(scan_id)
    scan.status, scan.finished_by, scan.finished_at = 'abandoned', by, now
    db.session.flush()
    return scan


# ── what the screens read ────────────────────────────────────────────────────

def scan_view(scan: PieceScan, *, with_lists=True) -> dict:
    """A scan as its screens show it: its facts, its completeness, its counts
    by verdict; with its reads -- judged live while open, as frozen after --
    and, finished, its expected pieces' verdicts."""
    safe = db.session.get(SafeBox, scan.safe_box_id)
    expected_rows = PieceScanExpected.query.filter_by(scan_id=scan.id).order_by(PieceScanExpected.id).all()
    expected = {e.item_id for e in expected_rows}
    reads = PieceScanRead.query.filter_by(scan_id=scan.id).order_by(PieceScanRead.id).all()
    open_ = scan.status == 'open'
    presses_of = dict(db.session.query(PieceScanEvent.value, db.func.count(db.distinct(PieceScanEvent.press)))
                      .filter(PieceScanEvent.scan_id == scan.id, PieceScanEvent.kind == 'read')
                      .group_by(PieceScanEvent.value).all())
    read_views = []
    for read in reads:
        said = judge(scan, read.value, expected=expected) if open_ else {
            'verdict': read.verdict, 'item_id': read.item_id, 'words': read.words, 'attempt_id': None,
            'unsettled': False}
        read_views.append({'id': read.id, 'value': read.value, 'first_press': read.first_press,
                           'presses': int(presses_of.get(read.value, 0)), 'verdict': said['verdict'],
                           'verdict_words': WORDS.get(said['verdict']), 'item_id': said['item_id'],
                           'words': said['words'], 'moved': read.moved,
                           'attempt_id': said['attempt_id'], 'unsettled': said['unsettled'],
                           'resolved_by': read.resolved_by, 'resolved_by_name': name_of(read.resolved_by)})
    counts: dict = {}
    for r in read_views:
        counts[r['verdict']] = counts.get(r['verdict'], 0) + 1
    found = {r['item_id'] for r in read_views if r['verdict'] == FOUND}
    # each piece read with its weight and what it is, and the grams found against the grams
    # expected (the owner's rehearsal, 23 Nov 2026: «عرض لبيانات مثل الوزن الممسوح»)
    ids = {r['item_id'] for r in read_views if r['item_id']} | set(expected)
    pieces = {i.id: i for i in Item.query.filter(Item.id.in_(ids))} if ids else {}
    names = _piece_names(pieces.values())
    for r in read_views:
        piece = pieces.get(r['item_id'])
        r.update(item_code=getattr(piece, 'item_code', None),
                 weight=round(float(piece.weight or 0), 3) if piece is not None else None,
                 piece_name=names.get(r['item_id']))
    grams_expected = round(sum(float(pieces[i].weight or 0) for i in expected if i in pieces), 3)
    grams_found = round(sum(float(pieces[i].weight or 0) for i in found & expected if i in pieces), 3)
    view = {'id': scan.id, 'safe_box_id': scan.safe_box_id, 'safe_name': getattr(safe, 'name', None),
            'kind': scan.kind, 'kind_words': KINDS.get(scan.kind), 'status': scan.status,
            'started_by': scan.started_by, 'started_at': scan.started_at.isoformat(),
            'started_by_name': name_of(scan.started_by),
            'finished_by': scan.finished_by, 'finished_by_name': name_of(scan.finished_by),
            'finished_at': scan.finished_at.isoformat() if scan.finished_at else None,
            'complete': scan.complete, 'early_reason': scan.early_reason, 'presses': scan.presses or 0,
            'expected': len(expected_rows), 'found': len(found & expected),
            'expected_grams': grams_expected, 'found_grams': grams_found,
            'section_id': scan.section_id, 'category_id': scan.category_id, 'scope_words': _scope_words(scan),
            'alerts': sum(1 for r in read_views if r['verdict'] not in (FOUND, OTHER_SCOPE)), 'counts': counts}
    if open_:
        view['completeness'] = completeness(scan)
    else:
        view['expected_counts'] = {}
        for row in expected_rows:
            view['expected_counts'][row.verdict] = view['expected_counts'].get(row.verdict, 0) + 1
    if with_lists:
        view['reads'] = read_views
        if not open_:
            items = {i.id: i for i in Item.query.filter(Item.id.in_(expected))} if expected else {}
            view['expected_pieces'] = [
                {'item_id': row.item_id, 'item_code': getattr(items.get(row.item_id), 'item_code', None),
                 'weight': float(getattr(items.get(row.item_id), 'weight', 0) or 0), 'verdict': row.verdict,
                 'verdict_words': WORDS.get(row.verdict), 'moved': row.moved}
                for row in expected_rows]
    return view


def _piece_names(pieces) -> dict:
    """{piece id: its model's name, else its category's} -- what it is, in a word."""
    from models import PieceModel
    pieces = list(pieces)
    models = {m.id: m.name for m in PieceModel.query.filter(
        PieceModel.id.in_({p.model_id for p in pieces if getattr(p, 'model_id', None)} or {-1}))}
    cats = {c.id: c.name for c in Category.query.filter(Category.id.in_({p.category_id for p in pieces} or {-1}))}
    return {p.id: models.get(getattr(p, 'model_id', None)) or cats.get(p.category_id) for p in pieces}


def name_of(username) -> str | None:
    """Who, by his name as everywhere else -- the login only when no name is known."""
    if not username:
        return None
    from models import AppUser, User
    for model in (User, AppUser):
        user = model.query.filter_by(username=username).first()
        if user is not None and (user.full_name or '').strip():
            return user.full_name.strip()
    return username


def _scope_words(scan: PieceScan) -> str:
    if scan.category_id is not None:
        return getattr(db.session.get(Category, scan.category_id), 'name', None) or 'تصنيف'
    if scan.section_id is not None:
        return f'قسم {getattr(db.session.get(ItemSection, scan.section_id), "name", None) or ""}'.strip()
    return 'كل القطع'


PERIODS = ('today', 'week', 'month')


def scans_list(*, limit=100, status=None, safe_box_id=None, period=None, now=None) -> list:
    """The scans, the newest first, with their counts -- or those of a status,
    a location, a period by the clock given (the owner, 22 Nov 2026: a log of
    daily counts): today, the last 7 days, this month."""
    from datetime import timedelta
    query = PieceScan.query
    if status is not None:
        query = query.filter(PieceScan.status == status)
    if safe_box_id is not None:
        query = query.filter(PieceScan.safe_box_id == int(safe_box_id))
    if period:
        if period not in PERIODS or now is None:
            raise ScanRefused('scan_period_invalid', 'الفترة: اليوم، أو آخر 7 أيام، أو هذا الشهر')
        day = now.replace(hour=0, minute=0, second=0, microsecond=0)
        since = {'today': day, 'week': day - timedelta(days=6), 'month': day.replace(day=1)}[period]
        query = query.filter(PieceScan.started_at >= since)
    rows = query.order_by(PieceScan.id.desc()).limit(int(limit)).all()
    return [scan_view(s, with_lists=False) for s in rows]
