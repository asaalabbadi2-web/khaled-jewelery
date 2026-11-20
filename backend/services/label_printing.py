"""The print engine: one for every label of a piece (ADR-097 ط2; the owner, 20 Nov 2026).

A label is printed by a job of its own, never inside the piece's saving
(law 1). The first print, a selection, all at once, a reprint: each is a
job here, run by run_job -- the difference only where the request came from
(law 5).

- request_print(): a job saved -- one request key one job (law 6); a reprint
  with its reason; one open job a piece.
- run_job(): in the coder's own request (no worker behind, law 8):
  the printer's turn (a session lock on its own connection, law 7) -- its
  status asked: not ready, PrinterNotReady, no attempt and no generation
  (the owner, after ط6) -- the attempt with its new generation committed
  BEFORE the label is sent (law 9) -- the label sent, its tag read back --
  the printer's status asked again.
  Read back and matching, and printed with no error: the tag mounted on the
  piece, a former one stopped, the job completed (laws 3, 4). Certain
  failures fail; an unknown end -- the line dropped after sending, nothing
  answered, the server stopped mid-way -- is needs_attention (law 10).
- resolve_attempt(): an unknown end settled by the handheld reader reading
  the label that came out (its own value: the attempt is confirmed, no new
  generation), or by the coder saying no label came out.
- A completed job run again prints nothing (law 6); a failed one runs a new
  attempt with a new generation.

What is known of an attempt is kept apart (ADR-097 §5): written and verified
from the read back; printed from the printer's status after -- «printed with
no error», never «the ink was seen».

Every commit is the caller's `commit` (the route's db.session.commit): the
attempt must be in the database before the printer hears of it.
"""
from __future__ import annotations

import time

from models import Item, LabelPrinter, PieceTag, PrintAttempt, PrintJob, db
from services.printer_link import UNREACHABLE, LinkLost, PrinterUnreachable, ZebraLink, answered_empty, read_back

OPEN_STATES = ('pending', 'printing', 'verifying', 'failed', 'needs_attention')
LOCK_BASE = 0x4B4A0000            # «KJ»: a printer's lock is this plus its id
# A worker never held long for the printer (ط6): a label takes about two
# seconds; past this wait the coder's screen asks again by itself
# (PrinterBusy). Production's workers serve one request each, so a gunicorn
# hung-request kill (HANG-001) stays: threads were tried and lost it.
LOCK_WAIT = 5.0

WORDS = {
    'not_written': 'لم تُكتب الرقاقة: أتلف الملصق الخارج وأعد المحاولة',
    'mismatch': 'قُرئت رقاقة غير المطلوبة: أتلف الملصق الخارج وأعد المحاولة',
    'link_lost': 'انقطع الاتصال بالطابعة أثناء الطباعة: إن خرج ملصق فاقرأه بالقارئ، وإلا قل «لم يخرج ملصق»',
    'no_answer': 'لم تردّ الطابعة بعد الإرسال: إن خرج ملصق فاقرأه بالقارئ، وإلا قل «لم يخرج ملصق»',
    'stopped_midway': 'توقّفت المحاولة قبل أن تكتمل: إن خرج ملصق فاقرأه بالقارئ، وإلا قل «لم يخرج ملصق»',
    'printed_with_error': 'كُتبت الرقاقة لكن الطابعة توقّفت بعدها: أتلف الملصق الخارج وأعد المحاولة',
    'unreachable': UNREACHABLE,
}


class PrintRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


class PrinterBusy(PrintRefused):
    """Its printer's turn did not come within LOCK_WAIT -- another label is
    printing. Nothing written: no attempt, no generation; the coder's screen
    asks again by itself, and the label prints after the other."""

    def __init__(self):
        super().__init__('printer_busy', 'الطابعة مشغولة ببطاقة أخرى: تُطبع بعدها')
        self.state = {'ready': True, 'busy': True, 'stops': [], 'message': self.message}


class PrinterNotReady(PrintRefused):
    """The printer asked before any attempt, and not ready -- no label, so no
    attempt and no generation (the owner, 20 Nov 2026, after ط6: nine presses
    on «إعادة المحاولة» with the cable out spent nine generations). The job
    stays as it was; *state* says why."""

    def __init__(self, state: dict):
        super().__init__(state['stops'][0] if state.get('stops') else 'not_ready', state.get('message') or '')
        self.state = state


# ── the request ──────────────────────────────────────────────────────────────

def default_printer():
    active = LabelPrinter.query.filter_by(is_active=True).order_by(LabelPrinter.id).all()
    if not active:
        raise PrintRefused('no_printer', 'لا طابعة بطاقات مفعّلة: يضيفها المدير في إعداد الطابعات')
    if len(active) > 1:
        raise PrintRefused('printer_not_chosen', 'أكثر من طابعة مفعّلة: اختر الطابعة')
    return active[0]


def request_print(piece: Item, *, request_key: str, by: str, now, kind: str = 'first', reason=None,
                  printer=None) -> PrintJob:
    """A job for *piece*'s label -- or the job its key already made (law 6)."""
    from services.pieces import active_tag, is_piece
    key = str(request_key or '').strip()
    if not key:
        raise PrintRefused('request_key_required', 'طلب الطباعة بلا مفتاح')
    same = PrintJob.query.filter_by(request_key=key).first()
    if same is not None:
        if same.item_id != piece.id:
            raise PrintRefused('request_key_reused', 'مفتاح الطلب لقطعة أخرى')
        return same
    if not is_piece(piece):
        raise PrintRefused('piece_unknown', 'البطاقة تُطبع لقطعة مرمَّزة')
    if kind not in ('first', 'reprint'):
        raise PrintRefused('print_kind_invalid', 'نوع الطباعة: الأولى أو إعادة الطباعة')
    reason = str(reason or '').strip() or None
    if kind == 'reprint' and reason is None:
        raise PrintRefused('reprint_reason_required', 'اكتب سبب إعادة الطباعة')
    if kind == 'first' and active_tag(piece) is not None:
        raise PrintRefused('piece_has_label', f'للقطعة {piece.item_code} بطاقة معتمدة: أعد طباعتها بسبب')
    open_job = PrintJob.query.filter(PrintJob.item_id == piece.id, PrintJob.status.in_(OPEN_STATES)).first()
    if open_job is not None:
        raise PrintRefused('job_open', f'للقطعة {piece.item_code} مهمة طباعة قائمة (#{open_job.id}): أكملها')
    printer = printer or default_printer()
    if not printer.is_active:
        raise PrintRefused('printer_inactive', f'الطابعة «{printer.name}» غير مفعّلة')
    job = PrintJob(item_id=piece.id, printer_id=printer.id, kind=kind, reason=reason, request_key=key,
                   status='pending', requested_by=by, requested_at=now)
    db.session.add(job)
    db.session.flush()
    return job


# ── the printer's turn ───────────────────────────────────────────────────────

class _Turn:
    """A printer's turn: a session advisory lock on a connection of its own --
    not the request's, whose commits would hand it back to the pool still
    holding the lock. A stopped worker closes it, and the lock goes with it."""

    def __init__(self, printer_id: int, wait: float, sleep=time.sleep):
        self.key, self.wait, self.sleep = LOCK_BASE + int(printer_id), wait, sleep
        self.conn = None

    def __enter__(self):
        from sqlalchemy import text
        self.conn = db.engine.connect()
        deadline = time.monotonic() + self.wait
        while True:
            if self.conn.execute(text('SELECT pg_try_advisory_lock(:k)'), {'k': self.key}).scalar():
                self.conn.commit()
                return True
            self.conn.rollback()
            if time.monotonic() >= deadline:
                self.conn.close()
                self.conn = None
                return False
            self.sleep(0.25)

    def __exit__(self, *exc):
        if self.conn is not None:
            from sqlalchemy import text
            try:
                self.conn.execute(text('SELECT pg_advisory_unlock(:k)'), {'k': self.key})
                self.conn.commit()
            finally:
                self.conn.close()
        return False


# ── the run ──────────────────────────────────────────────────────────────────

def _finish(attempt, job, *, status, clock, error=None, **facts):
    for k, v in facts.items():
        setattr(attempt, k, v)
    if error:
        attempt.error_code, attempt.error_message = error, WORDS.get(error, error)
    if status != 'needs_attention':
        attempt.finished_at = clock()
    job.status = status
    if status == 'completed':
        job.completed_at = attempt.finished_at


def _mount(attempt, job, piece, *, by, now):
    """The verified tag on the piece; a former one stopped first, its reason the job's (law 4)."""
    from services.pieces import active_tag
    former = active_tag(piece)
    if former is not None:
        former.stopped_at, former.stopped_by = now, by
        former.stop_reason = f'استُبدلت بالجيل {attempt.generation:04d}: {job.reason or "إعادة طباعة"}'[:200]
        db.session.flush()
    tag = PieceTag(item_id=piece.id, value=attempt.epc, technology='uhf_epc96', mounted_at=now, mounted_by=by,
                   generation=attempt.generation, attempt_id=attempt.id)
    db.session.add(tag)
    db.session.flush()
    return tag


def label_facts(piece: Item) -> dict:
    """What its label carries (ADR-097): its number, karat and weight -- its
    grams in the books, what is sold as gold: its standing weight when its
    stones count as gold, its net when they are priced apart, then marked
    «+St» (the owner, 20 Nov 2026) -- its model's name else its category's,
    its stones and its size: the printed label's and its preview's."""
    from models import Category, PieceModel, SizeSystemSize
    from services.pieces import STONES_PRICED, piece_weights
    model = db.session.get(PieceModel, piece.model_id) if piece.model_id else None
    category = db.session.get(Category, piece.category_id) if piece.category_id else None
    size = db.session.get(SizeSystemSize, piece.size_id) if piece.size_id else None
    return {'number': piece.item_code, 'karat': piece.karat, 'weight': piece.weight,
            'name': model.name if model else getattr(category, 'name', None),
            'stones': piece.stones_weight, 'size': getattr(size, 'label', None),
            'stones_out': piece_weights(piece)['stones_kind'] == STONES_PRICED}


def _label(piece: Item, epc: str) -> str:
    from services.piece_label import label_zpl
    facts = label_facts(piece)
    return label_zpl(facts.pop('number'), epc=epc, **facts)


def run_job(job: PrintJob, *, by: str, clock, commit, link=None, wait: float = LOCK_WAIT, sleep=time.sleep):
    """The job run once -- see the module. Returns the job; its last attempt
    says what happened. *link*: the printer's (ZebraLink by default)."""
    from services.pieces import next_generation
    if job.status == 'completed':
        return job                                          # law 6: never printed twice
    if job.status == 'needs_attention':
        raise PrintRefused('attempt_unresolved', 'محاولة سابقة لم يُعرف مصيرها: احسمها أولًا')
    printer = db.session.get(LabelPrinter, job.printer_id)
    link = link or ZebraLink(printer.host, printer.port)
    turn = _Turn(printer.id, wait, sleep)
    with turn as mine:
        if not mine:
            raise PrinterBusy()                             # nothing written: asked again by the screen
        db.session.refresh(job)
        if job.status == 'completed':
            return job
        stale = PrintAttempt.query.filter_by(job_id=job.id, finished_at=None).first()
        if stale is not None:
            # its run stopped mid-way (the lock is ours: no one is running it) -- unknown, never failed
            _finish(stale, job, status='needs_attention', clock=clock, error='stopped_midway')
            commit()
            return job
        # The printer asked first: not ready, no attempt and no generation --
        # nothing could be printed (the owner, 20 Nov 2026, after ط6).
        try:
            state = link.status()
        except PrinterUnreachable:
            state = {'ready': False, 'stops': ['unreachable'], 'message': UNREACHABLE}
        if not state['ready']:
            raise PrinterNotReady(state)

        piece = db.session.get(Item, job.item_id)
        generation = next_generation(piece)
        from services.pieces import epc_of
        attempt = PrintAttempt(job_id=job.id, generation=generation, epc=epc_of(piece.item_code, generation),
                               started_by=by, started_at=clock())
        db.session.add(attempt)
        job.status = 'printing'
        commit()                                            # law 9: saved before the label is sent

        zpl = _label(piece, attempt.epc)
        try:
            reply = link.send(zpl)
        except PrinterUnreachable:
            _finish(attempt, job, status='failed', clock=clock, error='unreachable', printed=False, written=False,
                    verified=False)
            commit()
            return job
        except LinkLost:
            attempt.sent_at = clock()
            _finish(attempt, job, status='needs_attention', clock=clock, error='link_lost')
            commit()
            return job
        attempt.sent_at = clock()
        job.status = 'verifying'
        value = read_back(reply)
        attempt.read_value = value
        if value is None and not answered_empty(reply):
            _finish(attempt, job, status='needs_attention', clock=clock, error='no_answer')
            commit()
            return job
        if value is None:
            _finish(attempt, job, status='failed', clock=clock, error='not_written', written=False, verified=False)
            commit()
            return job
        if value != attempt.epc:
            _finish(attempt, job, status='failed', clock=clock, error='mismatch', written=True, verified=False)
            commit()
            return job
        attempt.written, attempt.verified, attempt.verified_at = True, True, clock()
        try:
            after = link.status()
        except PrinterUnreachable:
            after = None
        if after is None or not after['ready']:
            # its tag written and read, its face not known printed: not adopted -- a new label
            _finish(attempt, job, status='failed', clock=clock, error='printed_with_error', printed=False)
            if after is not None:
                attempt.error_message = f'{WORDS["printed_with_error"]} ({after["message"]})'[:300]
            commit()
            return job
        attempt.printed, attempt.printed_at = True, clock()
        _finish(attempt, job, status='completed', clock=clock)
        _mount(attempt, job, piece, by=by, now=attempt.finished_at)
        commit()
        return job


# ── an unknown end, settled ──────────────────────────────────────────────────

def resolve_attempt(attempt: PrintAttempt, *, by: str, clock, commit, read_value=None, no_label=False,
                    destroyed=False) -> PrintJob:
    """An attempt whose end was not known, settled (law 10) by one of three
    statements, each its own (the owner, 20 Nov 2026) -- the coder's, under
    their name:
    - the label read by the handheld reader: its own value -- 24 characters,
      matched here, never shown to the screen to be copied -- confirms it, no
      new generation;
    - a label came out and was destroyed (`destroyed`): failed, its tag never
      adopted; read again later, it is said destroyed and still there;
    - no label came out (`no_label`): failed.
    The next attempt is a new generation either way failed."""
    job = db.session.get(PrintJob, attempt.job_id)
    if attempt.finished_at is not None or job.status != 'needs_attention':
        raise PrintRefused('attempt_settled', 'المحاولة محسومة من قبل')
    if sum(1 for said in (bool(read_value), bool(no_label), bool(destroyed)) if said) != 1:
        raise PrintRefused('resolve_how', 'اقرأ الملصق بالقارئ، أو قل «خرج ملصق وأتلفته»، أو «لم يخرج ملصق»')
    if no_label or destroyed:
        _finish(attempt, job, status='failed', clock=clock, resolution='no_label' if no_label else 'destroyed',
                resolved_by=by, printed=bool(destroyed), written=False if no_label else None, verified=False)
        commit()
        return job
    value = ''.join(str(read_value).split()).upper()
    from services.pieces import _valid_epc96
    if not _valid_epc96(value):
        raise PrintRefused('read_value_invalid', 'رمز الرقاقة 24 خانة من الأرقام والحروف A–F كما يكتبها القارئ')
    if value != attempt.epc:
        raise PrintRefused('read_other_tag', f'القارئ قرأ رقاقة أخرى ({value})، لا رقاقة هذه المحاولة')
    _finish(attempt, job, status='completed', clock=clock, resolution='reader', resolved_by=by, read_value=value,
            written=True, verified=True, verified_at=clock(), printed=True, printed_at=clock())
    _mount(attempt, job, db.session.get(Item, job.item_id), by=by, now=attempt.finished_at)
    commit()
    return job


def job_view(job: PrintJob) -> dict:
    attempts = PrintAttempt.query.filter_by(job_id=job.id).order_by(PrintAttempt.id).all()
    last = attempts[-1] if attempts else None
    piece = db.session.get(Item, job.item_id)
    return {
        'id': job.id, 'item_id': job.item_id, 'item_code': getattr(piece, 'item_code', None),
        'printer_id': job.printer_id, 'kind': job.kind, 'reason': job.reason, 'status': job.status,
        'requested_by': job.requested_by, 'requested_at': job.requested_at.isoformat() if job.requested_at else None,
        'completed_at': job.completed_at.isoformat() if job.completed_at else None,
        'attempts': len(attempts),
        'last_attempt': None if last is None else {
            # an attempt not settled keeps its value here: the reader's reading
            # is matched by the server, never copied off the screen
            'id': last.id, 'generation': last.generation,
            'epc': last.epc if last.finished_at is not None else None, 'printed': last.printed,
            'written': last.written, 'verified': last.verified, 'error_code': last.error_code,
            'message': last.error_message, 'resolution': last.resolution,
            'finished': last.finished_at is not None},
    }
