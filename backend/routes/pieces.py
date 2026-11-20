"""«محطة ترميز القطع» (ADR-087 R3.4): the station's routes.

GET  /api/pieces/pending          -- posted receipt lines of categories tracked
     by the piece with weight left to code: their pieces counted, the rest.
GET  /api/pieces/lines/<line_id>  -- a line and its pieces, each with its wage
     (read from its line, §6) or «بانتظار الفاتورة».
GET  /api/pieces/codings/<id>     -- a batch of existing stock and its pieces.
POST /api/pieces                  -- a piece under a line (line_id) or a batch
     (coding_id): weight, stones_weight, model_id, size_id (ADR-093), a
     batch's piece its wage (per gram, or the whole with wage_whole: true),
     request_key -- the save attempt's key: pressed twice, one.
GET  /api/pieces/weigh            -- line_id or coding_id, weight (the scale's),
     stones_weight: what the piece would be in the books before it is one --
     its grams of the source's gold, its net, the rest after it -- or the
     refusal its registration would meet (services/pieces.weigh). Nothing
     written; asked as the weight is typed.
GET  /api/pieces/wage-check       -- line_id or coding_id, model_id: the
     source's wage per gram against the model's expected one -- a warning.
GET  /api/pieces                  -- the pieces' list (the owner, 16 Nov 2026):
     q, category_id, karat, safe_box_id, state (in_stock | sold |
     returned_to_supplier | out | all; in_stock unless asked), sort
     (number | weight | name), dir (asc | desc), page, per_page, model_id
     and size_id (a number, or «none» for the pieces without) -- each piece
     with its place, state and receipt, and the shop's summary.
PATCH /api/pieces/<id>            -- its words (ADR-093 §5): name, description,
     model_id, size_id -- recorded; its book facts stay.
GET  /api/pieces/lookup?code=     -- a piece by its number: its view and
     where it is (the transfer screen, R3.6).
POST /api/pieces/<id>/print-jobs  -- its label printed and its tag written,
     read back and adopted (ADR-097): no tag is mounted by a press of a button
     -- the routes that did (/tag, /tag/replace) are gone (law 3).
GET  /api/pieces/by-tag/<value>   -- the piece a reader read.
GET  /api/stock-codings/free      -- what a location holds of a category not
     yet pieced nor promised to an open batch (safe_box_id, category_id).
GET  /api/wage-pools/cost         -- a category's wage cost a gram now, its
     pool's average (ADR-096 ت2): category_id, karat; what the sale screen
     shows, locked -- the sale's posting computes its own.
POST /api/stock-codings           -- «ترميز من المخزون الموجود»: a batch --
     safe_box_id, category_id, weight, note; no wage: each of its pieces is
     sent with its own (wage, wage_whole; ADR-096 §4).
The laws are services/pieces.py's; these only carry them.
"""
from datetime import datetime

from flask import Blueprint, g, jsonify, request
from sqlalchemy.exc import IntegrityError

from auth_decorators import require_permission
from models import Category, InvoiceItem, Item, SafeBox, StockCoding, db
from services.pieces import (PieceRefused, coded_lines, coding_view, free_grams, line_pieces, line_view, open_coding,
                             pending_lines, piece_source, piece_view, register_piece, reserved_grams)

pieces_bp = Blueprint('pieces', __name__)


def _by():
    return getattr(getattr(g, 'current_user', None), 'username', None) or 'system'


@pieces_bp.route('/pieces/pending', methods=['GET'])
@require_permission('items.view')
def station_pending():
    return jsonify({'lines': pending_lines()}), 200


@pieces_bp.route('/pieces/lines/<int:line_id>', methods=['GET'])
@require_permission('items.view')
def station_line(line_id: int):
    line = db.session.get(InvoiceItem, line_id)
    if line is None:
        return jsonify({'error': 'not_found', 'message': 'سطر الاستلام غير موجود'}), 404
    return jsonify({'line': line_view(line), 'pieces': [piece_view(p) for p in line_pieces(line)]}), 200


@pieces_bp.route('/pieces/invoices/<int:invoice_id>/coded-lines', methods=['GET'])
@require_permission('invoices.view')
def invoice_coded_lines(invoice_id: int):
    """A receipt's lines coded into pieces: what its supplier's return takes
    back by piece, and the rest (services/return_lines.supplier_return_pieces)."""
    return jsonify({'lines': {str(k): v for k, v in coded_lines(invoice_id).items()}}), 200


@pieces_bp.route('/pieces/codings/<int:coding_id>', methods=['GET'])
@require_permission('items.view')
def station_coding(coding_id: int):
    batch = db.session.get(StockCoding, coding_id)
    if batch is None:
        return jsonify({'error': 'not_found', 'message': 'دفعة الترميز غير موجودة'}), 404
    return jsonify({'line': coding_view(batch), 'pieces': [piece_view(p) for p in line_pieces(batch)]}), 200


def _view(source):
    return coding_view(source) if isinstance(source, StockCoding) else line_view(source)


def _saved(key):
    piece = Item.query.filter_by(request_key=key).first() if key else None
    if piece is None:
        return None
    return jsonify({'piece': piece_view(piece), 'line': _view(piece_source(piece)), 'already_saved': True}), 200


@pieces_bp.route('/pieces', methods=['POST'])
@require_permission('items.create')
def station_register():
    data = request.get_json(silent=True) or {}
    key = (str(data.get('request_key') or '').strip() or None)
    if key and len(key) > 64:
        return jsonify({'error': 'request_key_invalid', 'message': 'مفتاح المحاولة أطول من 64'}), 400
    saved = _saved(key)
    if saved is not None:
        return saved
    try:
        line = (db.session.get(StockCoding, int(data['coding_id'])) if data.get('coding_id')
                else db.session.get(InvoiceItem, int(data.get('line_id'))))
    except (TypeError, ValueError):
        line = None
    if line is None:
        return jsonify({'error': 'not_found', 'message': 'سطر الاستلام أو دفعة الترميز غير موجودة'}), 404
    try:
        with db.session.begin_nested():
            piece = register_piece(line, weight=data.get('weight'), stones_weight=data.get('stones_weight'),
                                   model_id=data.get('model_id'), size_id=data.get('size_id'),
                                   wage=data.get('wage'), wage_whole=data.get('wage_whole') is True,
                                   by=_by(), now=datetime.now(), request_key=key)
    except PieceRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    except IntegrityError:
        # two stations, one key, the same moment: the second meets the first's row
        db.session.rollback()
        saved = _saved(key)
        if saved is None:
            raise
        return saved
    db.session.commit()
    return jsonify({'piece': piece_view(piece), 'line': _view(line)}), 201


@pieces_bp.route('/pieces/weigh', methods=['GET'])
@require_permission('items.create')
def station_weigh():
    """A piece weighed, read before it is registered: {'weighed': ...} or
    {'refused': {code, message}} -- a 200 either way: an answer to a question,
    not a request refused."""
    from services.pieces import weigh
    try:
        source = (db.session.get(StockCoding, int(request.args['coding_id'])) if request.args.get('coding_id')
                  else db.session.get(InvoiceItem, int(request.args.get('line_id'))))
    except (TypeError, ValueError):
        source = None
    if source is None:
        return jsonify({'error': 'not_found', 'message': 'سطر الاستلام أو دفعة الترميز غير موجودة'}), 404
    try:
        weighed = weigh(source, weight=request.args.get('weight'),
                        stones_weight=request.args.get('stones_weight') or 0.0)
    except PieceRefused as refused:
        return jsonify({'weighed': None, 'refused': {'code': refused.code, 'message': refused.message}}), 200
    return jsonify({'weighed': weighed, 'refused': None}), 200


@pieces_bp.route('/pieces/wage-check', methods=['GET'])
@require_permission('items.view')
def station_wage_check():
    """A line's or a batch's wage per gram against a model's expected one
    (ADR-093 §1): line_id or coding_id, model_id -- a warning, never a refusal."""
    from models import PieceModel
    from services.pieces import wage_check
    try:
        source = (db.session.get(StockCoding, int(request.args['coding_id'])) if request.args.get('coding_id')
                  else db.session.get(InvoiceItem, int(request.args.get('line_id'))))
        model = db.session.get(PieceModel, int(request.args.get('model_id')))
    except (TypeError, ValueError):
        source = model = None
    if source is None or model is None:
        return jsonify({'error': 'not_found', 'message': 'السطر أو الموديل غير موجود'}), 404
    return jsonify(wage_check(source, model))


@pieces_bp.route('/pieces', methods=['GET'])
@require_permission('items.view')
def pieces_index():
    from services.pieces import PiecesFilterInvalid, pieces_list
    args = request.args

    def number(name):
        value = (args.get(name) or '').strip()
        return int(value) if value else None
    try:
        listed = pieces_list(q=args.get('q'), category_id=number('category_id'), karat=number('karat'),
                             safe_box_id=number('safe_box_id'), model_id=args.get('model_id'),
                             size_id=args.get('size_id'), state=args.get('state') or 'in_stock',
                             sort=args.get('sort') or 'number', descending=(args.get('dir') or 'desc') != 'asc',
                             page=args.get('page') or 1, per_page=args.get('per_page') or 25,
                             today=datetime.now(), untagged=args.get('untagged') in ('1', 'true'))
    except (PiecesFilterInvalid, ValueError) as refused:
        return jsonify({'error': 'pieces_filter_invalid', 'message': str(refused)}), 400
    return jsonify(listed), 200


@pieces_bp.route('/pieces/<int:piece_id>', methods=['PATCH'])
@require_permission('items.edit')
def piece_words(piece_id: int):
    """A piece's words (ADR-093 §5): name, description, model_id, size_id --
    what is given changes, recorded; its book facts stay."""
    from services.pieces import update_piece_words
    piece = Item.query.get_or_404(piece_id)
    data = request.get_json(silent=True) or {}
    try:
        changed = update_piece_words(piece, by=_by(), now=datetime.now(),
                                     **{k: data[k] for k in ('name', 'description', 'model_id', 'size_id')
                                        if k in data})
    except PieceRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    db.session.commit()
    return jsonify({'piece': piece_view(piece), 'changed': changed}), 200


@pieces_bp.route('/pieces/lookup', methods=['GET'])
@require_permission('items.view')
def piece_lookup():
    from services.pieces import is_piece, piece_location
    code = (request.args.get('code') or '').strip().upper()
    piece = Item.query.filter_by(item_code=code).first() if code else None
    if not is_piece(piece):
        return jsonify({'error': 'piece_unknown', 'message': f'لا قطعة بالرقم {code}'}), 404
    where = piece_location(piece)
    return jsonify({'piece': piece_view(piece),
                    'location': {'id': where.id, 'name': where.name} if where is not None else None}), 200


@pieces_bp.route('/pieces/by-tag/<value>', methods=['GET'])
@require_permission('items.view')
def piece_by_tag_route(value: str):
    from services.pieces import piece_by_tag, piece_location, tag_state
    piece = piece_by_tag(value)
    if piece is None:
        # A stopped tag, an attempt's never confirmed, or unknown: said, not a piece (ADR-097 §2).
        state = tag_state(value)
        return jsonify({'error': f'tag_{state["state"]}', 'message': state['message'], 'tag': state}), 404
    where = piece_location(piece)
    return jsonify({'piece': piece_view(piece),
                    'location': {'id': where.id, 'name': where.name} if where is not None else None}), 200


@pieces_bp.route('/wage-pools/cost', methods=['GET'])
@require_permission('invoices.view')
def wage_pool_cost():
    from services.wage_ledger import pool_average, wage_pools_on
    try:
        karat = int(round(float(request.args.get('karat'))))
        category_id = int(request.args['category_id']) if request.args.get('category_id') else None
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid', 'message': 'العيار والتصنيف أرقام'}), 400
    return jsonify({**pool_average(karat, category_id), 'karat': karat, 'category_id': category_id,
                    'active': wage_pools_on(datetime.now())}), 200


@pieces_bp.route('/stock-codings/free', methods=['GET'])
@require_permission('items.view')
def stock_coding_free():
    try:
        safe = db.session.get(SafeBox, int(request.args.get('safe_box_id')))
        category = db.session.get(Category, int(request.args.get('category_id')))
    except (TypeError, ValueError):
        safe = category = None
    if safe is None or category is None:
        return jsonify({'error': 'not_found', 'message': 'الخزينة أو التصنيف غير موجود'}), 404
    karat = int(round(float(category.karat or 0)))
    free = free_grams(safe, karat, category.id)
    reserved = reserved_grams(safe.id, karat, category.id)
    # From 2027's opening each piece takes its pool's average, not a wage written (ADR-096 ت3).
    from services.wage_ledger import pool_average, wage_pools_on
    from_pool = wage_pools_on(datetime.now())
    return jsonify({'free': free, 'reserved': reserved, 'room': round(max(free - reserved, 0.0), 3),
                    'karat': karat, 'wage_from_pool': from_pool,
                    'pool_wage_per_gram': pool_average(karat, category.id)['per_gram'] if from_pool else None}), 200


@pieces_bp.route('/stock-codings', methods=['POST'])
@require_permission('items.create')
def stock_coding_open():
    data = request.get_json(silent=True) or {}
    if data.get('wage_per_gram') is not None:
        return jsonify({'error': 'coding_wage_by_piece',
                        'message': 'الدفعة بلا أجرة: تُكتب أجرة كل قطعة عند تسجيلها'}), 400
    try:
        batch = open_coding(safe_box_id=data.get('safe_box_id'), category_id=data.get('category_id'),
                            weight=data.get('weight'), note=data.get('note'), by=_by(), now=datetime.now())
    except PieceRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.code, 'message': refused.message}), 400
    db.session.commit()
    return jsonify({'line': coding_view(batch), 'pieces': []}), 201


# ── a piece's label: print jobs (ADR-097 ط2) ─────────────────────────────────

def _print_refused(refused):
    db.session.rollback()
    return jsonify({'error': refused.code, 'message': refused.message}), 400


@pieces_bp.route('/pieces/<int:piece_id>/print-jobs', methods=['POST'])
@require_permission('items.create')
def piece_print_job(piece_id: int):
    """A label's job saved (law 9), then run in this request unless `run` is false
    -- the station's «تسجيل فقط» leaves it waiting. Sent again with its key: the
    same job, never a second label (law 6)."""
    from models import LabelPrinter
    from services.label_printing import PrinterBusy, PrinterNotReady, PrintRefused, job_view, request_print, run_job
    data = request.get_json(silent=True) or {}
    piece = db.session.get(Item, piece_id)
    if piece is None:
        return jsonify({'error': 'not_found', 'message': 'القطعة غير موجودة'}), 404
    printer = db.session.get(LabelPrinter, int(data['printer_id'])) if data.get('printer_id') else None
    try:
        job = request_print(piece, request_key=data.get('request_key'), kind=data.get('kind') or 'first',
                            reason=data.get('reason'), printer=printer, by=_by(), now=datetime.now())
        db.session.commit()
        if data.get('run', True) is not False:
            run_job(job, by=_by(), clock=datetime.now, commit=db.session.commit)
    except (PrinterNotReady, PrinterBusy) as not_ready:
        # saved and waiting: the printer said why -- no attempt, no generation
        return jsonify({'job': job_view(job), 'printer': not_ready.state}), 200
    except PrintRefused as refused:
        return _print_refused(refused)
    return jsonify({'job': job_view(job)}), 200


@pieces_bp.route('/print-jobs/<int:job_id>/run', methods=['POST'])
@require_permission('items.create')
def print_job_run(job_id: int):
    """Run a job again: pending, or failed -- a new attempt, a new generation."""
    from models import PrintJob
    from services.label_printing import PrinterBusy, PrinterNotReady, PrintRefused, job_view, run_job
    job = db.session.get(PrintJob, job_id)
    if job is None:
        return jsonify({'error': 'not_found', 'message': 'مهمة الطباعة غير موجودة'}), 404
    try:
        run_job(job, by=_by(), clock=datetime.now, commit=db.session.commit)
    except (PrinterNotReady, PrinterBusy) as not_ready:
        return jsonify({'job': job_view(job), 'printer': not_ready.state}), 200
    except PrintRefused as refused:
        return _print_refused(refused)
    return jsonify({'job': job_view(job)}), 200


@pieces_bp.route('/print-jobs/<int:job_id>', methods=['GET'])
@require_permission('items.view')
def print_job_read(job_id: int):
    """A job's state -- asked again after a dropped answer, it consumes nothing."""
    from models import PrintJob
    from services.label_printing import job_view
    job = db.session.get(PrintJob, job_id)
    if job is None:
        return jsonify({'error': 'not_found', 'message': 'مهمة الطباعة غير موجودة'}), 404
    return jsonify({'job': job_view(job)}), 200


@pieces_bp.route('/print-attempts/<int:attempt_id>/resolve', methods=['POST'])
@require_permission('items.create')
def print_attempt_resolve(attempt_id: int):
    """An unknown end settled: `read_value` the handheld reader read off the label, or `no_label`."""
    from models import PrintAttempt
    from services.label_printing import PrintRefused, job_view, resolve_attempt
    data = request.get_json(silent=True) or {}
    attempt = db.session.get(PrintAttempt, attempt_id)
    if attempt is None:
        return jsonify({'error': 'not_found', 'message': 'المحاولة غير موجودة'}), 404
    try:
        job = resolve_attempt(attempt, read_value=data.get('read_value'), no_label=bool(data.get('no_label')),
                              by=_by(), clock=datetime.now, commit=db.session.commit)
    except PrintRefused as refused:
        return _print_refused(refused)
    return jsonify({'job': job_view(job)}), 200


def _printer_view(p):
    return {'id': p.id, 'name': p.name, 'host': p.host, 'port': p.port, 'is_active': p.is_active,
            'font_installed_at': p.font_installed_at.isoformat() if p.font_installed_at else None}


@pieces_bp.route('/label-printers', methods=['GET'])
@require_permission('items.view')
def label_printers():
    from models import LabelPrinter
    return jsonify({'printers': [_printer_view(p) for p in LabelPrinter.query.order_by(LabelPrinter.id)]}), 200


@pieces_bp.route('/label-printers', methods=['POST'])
@require_permission('system.settings')
def label_printer_add():
    """A printer on the shop's network -- a row, not a setting (ADR-097 §3)."""
    from models import LabelPrinter
    data = request.get_json(silent=True) or {}
    name, host = str(data.get('name') or '').strip(), str(data.get('host') or '').strip()
    if not name or not host:
        return jsonify({'error': 'printer_name_host', 'message': 'اسم الطابعة وعنوانها على الشبكة'}), 400
    try:
        port = int(data.get('port') or 9100)
    except (TypeError, ValueError):
        return jsonify({'error': 'printer_port', 'message': 'منفذ الطابعة رقم'}), 400
    if LabelPrinter.query.filter_by(name=name).first() is not None:
        return jsonify({'error': 'printer_name_taken', 'message': f'طابعة باسم «{name}» موجودة'}), 400
    printer = LabelPrinter(name=name, host=host, port=port, is_active=True, created_at=datetime.now(),
                           created_by=_by())
    db.session.add(printer)
    db.session.commit()
    return jsonify({'printer': _printer_view(printer)}), 201


@pieces_bp.route('/print-jobs', methods=['GET'])
@require_permission('items.view')
def print_jobs_open():
    """The labels waiting (ADR-097 §8): the jobs not completed -- pending, failed,
    or needing attention -- the oldest first, and their counts. «معالجة الفشل»."""
    from models import PrintJob
    from services.label_printing import job_view
    jobs = (PrintJob.query.filter(PrintJob.status.in_(('pending', 'printing', 'verifying', 'failed',
                                                      'needs_attention')))
            .order_by(PrintJob.id).all())
    counts = {'pending': 0, 'failed': 0, 'needs_attention': 0}
    for j in jobs:
        key = 'pending' if j.status in ('pending', 'printing', 'verifying') else j.status
        counts[key] += 1
    return jsonify({'jobs': [job_view(j) for j in jobs], 'counts': counts}), 200


@pieces_bp.route('/label-printers/<int:printer_id>/status', methods=['GET'])
@require_permission('items.view')
def label_printer_status(printer_id: int):
    """Ready, or what stops it -- in the shop's words; «لا تردّ» when it does not answer."""
    from models import LabelPrinter
    from services.printer_link import UNREACHABLE, PrinterUnreachable, ZebraLink
    printer = db.session.get(LabelPrinter, printer_id)
    if printer is None:
        return jsonify({'error': 'not_found', 'message': 'الطابعة غير موجودة'}), 404
    try:
        state = ZebraLink(printer.host, printer.port).status()
    except PrinterUnreachable:
        state = {'ready': False, 'stops': ['unreachable'], 'message': UNREACHABLE}
    return jsonify({'printer': _printer_view(printer), 'status': state}), 200


@pieces_bp.route('/pieces/<int:piece_id>/label-preview', methods=['GET'])
@require_permission('items.view')
def piece_label_preview(piece_id: int):
    """What its label's faces say -- from the printed label's own source (ADR-097 ط5)."""
    from services.label_printing import label_facts
    from services.piece_label import label_faces
    piece = db.session.get(Item, piece_id)
    if piece is None:
        return jsonify({'error': 'not_found', 'message': 'القطعة غير موجودة'}), 404
    facts = label_facts(piece)
    return jsonify({'faces': label_faces(facts.pop('number'), **facts)}), 200


def _printer_or_404(printer_id):
    from models import LabelPrinter
    return db.session.get(LabelPrinter, printer_id)


@pieces_bp.route('/label-printers/<int:printer_id>', methods=['PATCH'])
@require_permission('system.settings')
def label_printer_edit(printer_id: int):
    """Its name, address, port, on or off -- the manager's (ADR-097 §7)."""
    from models import LabelPrinter
    printer = _printer_or_404(printer_id)
    if printer is None:
        return jsonify({'error': 'not_found', 'message': 'الطابعة غير موجودة'}), 404
    data = request.get_json(silent=True) or {}
    if 'name' in data:
        name = str(data.get('name') or '').strip()
        if not name:
            return jsonify({'error': 'printer_name_host', 'message': 'اسم الطابعة لا يُترك فارغًا'}), 400
        if LabelPrinter.query.filter(LabelPrinter.name == name, LabelPrinter.id != printer.id).first():
            return jsonify({'error': 'printer_name_taken', 'message': f'طابعة باسم «{name}» موجودة'}), 400
        printer.name = name
    if 'host' in data:
        host = str(data.get('host') or '').strip()
        if not host:
            return jsonify({'error': 'printer_name_host', 'message': 'عنوان الطابعة لا يُترك فارغًا'}), 400
        printer.host = host
    if 'port' in data:
        try:
            printer.port = int(data.get('port'))
        except (TypeError, ValueError):
            return jsonify({'error': 'printer_port', 'message': 'منفذ الطابعة رقم'}), 400
    if 'is_active' in data:
        printer.is_active = bool(data.get('is_active'))
    db.session.commit()
    return jsonify({'printer': _printer_view(printer)}), 200


def _printer_call(printer_id: int, what):
    """*what*(link, printer) on the printer -- «لا تردّ» when it does not answer."""
    from services.printer_link import UNREACHABLE, PrinterUnreachable, ZebraLink
    printer = _printer_or_404(printer_id)
    if printer is None:
        return jsonify({'error': 'not_found', 'message': 'الطابعة غير موجودة'}), 404
    try:
        message = what(ZebraLink(printer.host, printer.port), printer)
    except PrinterUnreachable:
        return jsonify({'error': 'printer_unreachable', 'message': UNREACHABLE}), 400
    return jsonify({'printer': _printer_view(printer), 'message': message}), 200


@pieces_bp.route('/label-printers/<int:printer_id>/install-font', methods=['POST'])
@require_permission('system.settings')
def label_printer_install_font(printer_id: int):
    """Cairo kept in the printer's flash -- once a printer; read back from its listing."""
    from services.piece_label import FONT_ON_PRINTER, font_upload

    def install(link, printer):
        link.exchange(font_upload(), wait=4.0)
        listed = link.exchange(f'^XA^HW{FONT_ON_PRINTER.split(".")[0]}.*^XZ\n', wait=4.0)
        if FONT_ON_PRINTER not in listed:
            return 'أُرسل الخط لكنه لم يظهر في ذاكرة الطابعة: أعد المحاولة'
        printer.font_installed_at = datetime.now()
        db.session.commit()
        return 'الخط في ذاكرة الطابعة'
    return _printer_call(printer_id, install)


@pieces_bp.route('/label-printers/<int:printer_id>/calibrate', methods=['POST'])
@require_permission('system.settings')
def label_printer_calibrate(printer_id: int):
    """The labels measured, then the tag's position -- a few blank labels and the printer's own report."""
    from services.printer_link import CALIBRATE

    def calibrate(link, printer):
        link.exchange(CALIBRATE, wait=2.0)
        return 'أُرسلت المعايرة: تُخرج الطابعة بضع بطاقات ثم ورقة موضع الرقاقة'
    return _printer_call(printer_id, calibrate)


@pieces_bp.route('/label-printers/<int:printer_id>/test-label', methods=['POST'])
@require_permission('system.settings')
def label_printer_test_label(printer_id: int):
    """One label of the design, its faces only -- no tag written, recorded nowhere."""
    from services.piece_label import label_zpl

    def test(link, printer):
        state = link.status()
        if not state['ready']:
            return state['message']
        link.exchange(label_zpl('KJ-999999', karat='21', weight=12.4, name='بطاقة تجربة', stones=0.35, size='18',
                                write_tag=False), wait=3.0)
        return 'طُبعت بطاقة تجربة بلا رقاقة: أتلفها بعد النظر فيها'
    return _printer_call(printer_id, test)
