import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../models/category_model.dart';
import '../models/safe_box_model.dart';
import '../theme/app_breakpoints.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/inline_number_cell.dart' show readTypedNumber;
import '../widgets/label_preview.dart';
import '../widgets/piece_label_actions.dart';
import 'label_printers_screen.dart';
import 'piece_model_form_screen.dart' show ModelImage;

/// «محطة ترميز القطع» (ADR-087 R3.4): the pieces of a received line, one by
/// one -- each weighed (typed until the scale is linked, R5), numbered by the
/// server «KJ-», its wage read from its line or awaiting the invoice. The
/// pieces of a line weigh no more than it; the rest stays weight in its
/// category. A batch of the stock a location already holds is coded the same
/// way (R3.5), and takes no wage: each of its pieces is written its own, per
/// gram or the piece's whole (ADR-096 §4; the owner, 19 Nov 2026). The laws
/// are the server's: this screen sends and says.
class PieceStationScreen extends StatefulWidget {
  const PieceStationScreen({super.key, this.api});
  final ApiService? api;

  @override
  State<PieceStationScreen> createState() => _PieceStationScreenState();
}

class _PieceStationScreenState extends State<PieceStationScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>>? _pending;
  Object? _error;

  Map<String, dynamic>? _line;
  List<Map<String, dynamic>> _pieces = const [];
  Map<String, dynamic>? _last;
  bool _saving = false;
  String? _requestKey;

  // Its label (ADR-097): printed at once by default, «تسجيل فقط» leaves it
  // waiting; the piece is saved either way, its label a job of its own. The
  // printer's state and the labels waiting are read again after each.
  bool _autoPrint = true;
  int? _printerId;
  Map<String, dynamic>? _printerState;
  Map<String, dynamic> _queueCounts = const {};
  List<Map<String, dynamic>> _openJobs = const [];
  final Set<int> _printing = {};

  /// The printer's state read again by itself while the station is open (the
  /// owner, 20 Nov 2026, after ط6): back from a cut cable, it says «جاهزة»
  /// with no press.
  static const printerEvery = Duration(seconds: 15);
  Timer? _printerTimer;
  late final PieceLabelActions _labels = PieceLabelActions(
    api: _api,
    onLabel: _setLabel,
    onBusy: (id, busy) {
      if (mounted) setState(() => busy ? _printing.add(id) : _printing.remove(id));
    },
    afterEach: () {
      _refreshQueue();
      _loadPrinterState();
    },
  );

  final _weight = TextEditingController();
  final _stones = TextEditingController();
  final _stonesFocus = FocusNode();
  bool _stonesOpen = false;

  /// The piece as the server reads it while its weight is typed (the owner,
  /// 20 Nov 2026): its net, its stones, the rest after it -- or the refusal
  /// its registration would meet. The screen subtracts nothing.
  Map<String, dynamic>? _weighed;
  Timer? _weighTimer;
  int _weighAsked = 0;
  static const weighAfter = Duration(milliseconds: 300);
  final _weightFocus = FocusNode();
  // A batch's piece: its own wage, per gram or its whole -- the way kept for
  // the next piece, the figure not.
  final _wage = TextEditingController();
  final _wageFocus = FocusNode();
  bool _wageWhole = false;

  // The model and the size (ADR-093 M2): the model chosen once for the line,
  // the size kept for the next piece; both optional.
  List<Map<String, dynamic>> _models = const [];
  List<Map<String, dynamic>> _systemSizes = const [];
  bool _modelsFailed = false;
  Map<String, dynamic>? _model;
  int? _sizeId;
  Map<String, dynamic>? _wageCheck;

  @override
  void initState() {
    super.initState();
    _loadPending();
    _loadPrinter();
    _printerTimer = Timer.periodic(printerEvery, (_) => _loadPrinterState());
  }

  @override
  void dispose() {
    _printerTimer?.cancel();
    _weighTimer?.cancel();
    _weight.dispose();
    _stones.dispose();
    _stonesFocus.dispose();
    _weightFocus.dispose();
    _wage.dispose();
    _wageFocus.dispose();
    super.dispose();
  }

  Future<void> _loadPending() async {
    setState(() => _error = null);
    try {
      final pending = await _api.piecesPending();
      if (mounted) setState(() => _pending = pending);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static bool _isBatch(Map<String, dynamic> l) => l['kind'] == 'stock';

  Future<void> _open(Map<String, dynamic> l) async {
    try {
      final body = _isBatch(l)
          ? await _api.pieceCoding(l['coding_id'] as int)
          : await _api.pieceLine(l['line_id'] as int);
      if (mounted) _show(body);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  void _show(Map<String, dynamic> body) {
    setState(() {
      _line = body['line'] as Map<String, dynamic>;
      _pieces = (body['pieces'] as List? ?? []).cast<Map<String, dynamic>>();
      _last = null;
      _requestKey = null;
      _weight.clear();
      _stones.clear();
      _stonesOpen = false;
      _weighed = null;
      _model = null;
      _sizeId = null;
      _wageCheck = null;
    });
    _weightFocus.requestFocus();
    _loadModels(body['line'] as Map<String, dynamic>);
  }

  /// The line's category's models and its size system's sizes.
  Future<void> _loadModels(Map<String, dynamic> line) async {
    try {
      final models = await _api.getPieceModels(categoryId: line['category_id'] as int?);
      final systemId = line['size_system_id'];
      var sizes = const <Map<String, dynamic>>[];
      if (systemId != null) {
        final systems = await _api.getSizeSystems();
        final system = systems.where((s) => s['id'] == systemId).firstOrNull;
        sizes = [for (final s in (system?['sizes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
      }
      if (!mounted || _line?['category_id'] != line['category_id']) return;
      setState(() {
        _models = models;
        _systemSizes = sizes;
        _modelsFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _modelsFailed = true);
    }
  }

  /// The sizes offered: the model's when it names them, else its category's system's.
  List<Map<String, dynamic>> get _offeredSizes {
    final named = [for (final s in (_model?['sizes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    return named.isNotEmpty ? named : _systemSizes;
  }

  Future<void> _chooseModel() async {
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              key: const Key('station-model-none'),
              leading: const Icon(Icons.block),
              title: const Text('بلا موديل'),
              onTap: () => Navigator.pop(context, const <String, dynamic>{}),
            ),
            for (final m in _models)
              ListTile(
                key: Key('station-model-${m['id']}'),
                leading: SizedBox(
                  width: 56,
                  height: 56,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ModelImage(api: _api, attachmentId: m['thumbnail_id'] as int?),
                  ),
                ),
                title: Text('${m['name']}'),
                subtitle: Text('${m['supplier_code'] ?? ''}'),
                onTap: () => Navigator.pop(context, m),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _model = chosen.isEmpty ? null : chosen;
      _wageCheck = null;
      if (!_offeredSizes.any((s) => s['id'] == _sizeId)) _sizeId = null;
    });
    final line = _line;
    final model = _model;
    if (line == null || model == null) return;
    try {
      final check = await _api.pieceWageCheck(
        lineId: _isBatch(line) ? null : line['line_id'] as int,
        codingId: _isBatch(line) ? line['coding_id'] as int : null,
        modelId: model['id'] as int,
      );
      if (mounted && _model?['id'] == model['id']) setState(() => _wageCheck = check);
    } catch (_) {
      // the warning is a help: without it the piece is still its invoice's
    }
  }

  // ── its label (ADR-097) ────────────────────────────────────────────────

  /// The printer and the labels waiting: read, never a reason to stop coding.
  Future<void> _loadPrinter() async {
    try {
      final printers = ((await _api.labelPrinters())['printers'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((p) => p['is_active'] == true)
          .toList();
      if (!mounted) return;
      setState(() => _printerId = printers.isEmpty ? null : printers.first['id'] as int);
      if (_printerId != null) {
        final state = await _api.labelPrinterStatus(_printerId!);
        if (mounted) setState(() => _printerState = state['status'] as Map<String, dynamic>?);
      }
    } catch (_) {
      if (mounted) setState(() => _printerState = null);
    }
    await _refreshQueue();
  }

  Future<void> _refreshQueue() async {
    try {
      final open = await _api.printJobsOpen();
      if (!mounted) return;
      setState(() {
        _queueCounts = (open['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
        _openJobs = (open['jobs'] as List? ?? []).cast<Map<String, dynamic>>();
      });
    } catch (_) {}
  }

  void _setLabel(int pieceId, Map<String, dynamic> label) {
    Map<String, dynamic> withIt(Map<String, dynamic> p) => p['id'] == pieceId ? {...p, 'label': label} : p;
    setState(() {
      _pieces = [for (final p in _pieces) withIt(p)];
      if (_last != null) _last = withIt(_last!);
    });
  }

  Future<void> _loadPrinterState() async {
    if (_printerId == null) return;
    try {
      final state = await _api.labelPrinterStatus(_printerId!);
      if (mounted) setState(() => _printerState = state['status'] as Map<String, dynamic>?);
    } catch (_) {}
  }

  /// Zone 1, the station's bar: the printer's state, the labels waiting or
  /// failed -- said only when there are some -- and how a piece's label is
  /// printed. Calm when all is well; the error's colour only for a stop.
  Widget _printerBar(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final state = _printerState;
    final ready = state?['ready'] == true;
    final pending = (_queueCounts['pending'] as num?)?.toInt() ?? 0;
    final failed =
        ((_queueCounts['failed'] as num?)?.toInt() ?? 0) + ((_queueCounts['needs_attention'] as num?)?.toInt() ?? 0);
    final text = _printerId == null
        ? 'لا طابعة بطاقات مفعّلة'
        : state == null
        ? 'حالة الطابعة غير معروفة'
        : ready
        ? 'الطابعة جاهزة'
        : '${state['message'] ?? 'الطابعة متوقفة'}';
    final ink = ready ? theme.colorScheme.onSurface : theme.colorScheme.onErrorContainer;
    final said = Row(
      children: [
        Icon(ready ? Icons.print : Icons.print_disabled, color: ready ? tones.ready.fg : ink),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            key: const Key('station-printer'),
            style: TextStyle(color: ink),
          ),
        ),
      ],
    );
    final counts = [if (pending > 0) 'بانتظار البطاقة $pending', if (failed > 0) 'فاشلة $failed'];
    final queue = counts.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                counts.join(' · '),
                key: const Key('station-queue'),
                style: TextStyle(color: ink),
              ),
              if (failed > 0)
                TextButton(key: const Key('station-failures'), onPressed: _failures, child: const Text('معالجة الفشل')),
            ],
          );
    // how the next piece's label is printed: the station's, beside its printer
    final mode = _line == null
        ? null
        : SegmentedButton<bool>(
            key: const Key('station-print-mode'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: true, label: Text('طباعة تلقائية')),
              ButtonSegment(value: false, label: Text('تسجيل فقط')),
            ],
            selected: {_autoPrint},
            onSelectionChanged: (v) => setState(() => _autoPrint = v.first),
          );
    final acts = <Widget>[
      IconButton(
        key: const Key('station-printer-refresh'),
        tooltip: 'سؤال الطابعة',
        icon: const Icon(Icons.refresh),
        onPressed: _loadPrinter,
      ),
      // the printers are the manager's (system.settings)
      if (Provider.of<AuthProvider?>(context, listen: false)?.hasPermission('system.settings') == true)
        IconButton(
          key: const Key('station-printers-setup'),
          tooltip: 'إعداد الطابعات',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => LabelPrintersScreen(api: _api))).then((_) => _loadPrinter()),
        ),
    ];
    return Material(
      key: const Key('station-bar'),
      color: ready ? theme.colorScheme.surfaceContainer : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        // a phone: its words on a line of their own, never squeezed letter by letter
        child: AppBreakpoints.isPhone(context)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: said),
                      ...acts,
                    ],
                  ),
                  if (queue != null) Align(alignment: AlignmentDirectional.centerStart, child: queue),
                  if (mode != null) SizedBox(width: double.infinity, child: mode),
                ],
              )
            : Row(
                children: [
                  Expanded(child: said),
                  if (queue != null) ...[queue, const SizedBox(width: 12)],
                  if (mode != null) mode,
                  ...acts,
                ],
              ),
      ),
    );
  }

  /// The choices kept for the next piece, said where the weight is typed (ر1):
  /// a size kept by mistake is seen before ten pieces carry it.
  Widget _current(BuildContext context) {
    final theme = Theme.of(context);
    final size = _offeredSizes.where((s) => s['id'] == _sizeId).toList();
    final words = [
      _model == null ? 'بلا موديل' : '${_model!['name']}',
      if (_offeredSizes.isNotEmpty) size.isEmpty ? 'بلا مقاس' : 'مقاس ${size.first['label']}',
      _autoPrint ? 'طباعة تلقائية' : 'تسجيل فقط',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.tune, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              words.join(' · '),
              key: const Key('station-current'),
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// A weight far from the line's own pieces -- 143.7 typed for 14.37 -- asked
  /// before it is sent (ر1): a piece is never deleted once registered. Only the
  /// typing is checked here; the server stays the judge of the line's rest.
  Future<bool> _weightLooksRight(double weight) async {
    final others = [
      // the scale's figure against the scale's: the pieces' standing weights
      for (final p in _pieces)
        if (((p['standing_weight'] ?? p['weight']) as num? ?? 0) > 0)
          ((p['standing_weight'] ?? p['weight']) as num).toDouble(),
    ];
    if (others.length < 2) return true;
    final average = others.reduce((a, b) => a + b) / others.length;
    if (weight <= average * 2 && weight >= average / 2) return true;
    final tenth = weight / 10;
    final guess = (tenth >= average / 2 && tenth <= average * 2) ? tenth : null;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          key: const Key('weight-unusual'),
          title: Text('وزن غير معتاد: ${_g(weight)} جم'),
          content: Text(
            'متوسط قطع السطر ${_g(average)} جم.'
            '${guess == null ? '' : ' لعلّ الوزن ${_g(guess)} جم؟'}',
          ),
          actions: [
            FilledButton(
              key: const Key('weight-fix'),
              autofocus: true,
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('تصحيح الوزن'),
            ),
            TextButton(
              key: const Key('weight-confirm'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('الوزن صحيح، سجّل'),
            ),
          ],
        ),
      ),
    );
    return sure == true;
  }

  /// The failed and unknown jobs, each with its action.
  Future<void> _failures() async {
    await _refreshQueue();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => Directionality(
        textDirection: TextDirection.rtl,
        child: ListView(
          key: const Key('station-failures-sheet'),
          shrinkWrap: true,
          children: [
            for (final j in _openJobs.where((j) => j['status'] == 'failed' || j['status'] == 'needs_attention'))
              ListTile(
                title: Text('${j['item_code']}', textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                subtitle: Text('${(j['last_attempt'] as Map?)?['message'] ?? ''}'),
                trailing: j['status'] == 'failed'
                    ? TextButton(
                        onPressed: () {
                          Navigator.of(sheet).pop();
                          _labels.retry(context, j['item_id'] as int, j['id'] as int);
                        },
                        child: const Text('إعادة المحاولة'),
                      )
                    : TextButton(
                        onPressed: () {
                          Navigator.of(sheet).pop();
                          _labels.resolve(
                            context,
                            j['item_id'] as int,
                            '${j['item_code']}',
                            (j['last_attempt'] as Map)['id'] as int,
                          );
                        },
                        child: const Text('حسم المحاولة'),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  /// «ترميز من المخزون الموجود»: a batch opened, then coded here.
  Future<void> _fromStock() async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FromStockDialog(api: _api),
    );
    if (body == null || !mounted) return;
    try {
      final opened = await _api.openStockCoding(body);
      if (mounted) _show(opened);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _close() async {
    setState(() {
      _line = null;
      _pieces = const [];
      _last = null;
    });
    await _loadPending();
  }

  Future<void> _register() async {
    final line = _line;
    final weight = readTypedNumber(_weight.text) ?? 0;
    if (line == null || _saving) return;
    if (weight <= 0) {
      AppFeedback.warning(context, 'أدخل وزن القطعة');
      _weightFocus.requestFocus();
      return;
    }
    if (_requestKey == null && !await _weightLooksRight(weight)) {
      if (mounted) _weightFocus.requestFocus();
      return;
    }
    if (!mounted) return;
    final byPiece = _wageByPiece(line);
    final wage = byPiece ? readTypedNumber(_wage.text) : null;
    if (byPiece && (wage == null || wage < 0)) {
      AppFeedback.warning(context, 'أدخل أجرة القطعة: صفر أو أكثر');
      _wageFocus.requestFocus();
      return;
    }
    // One attempt, one key: sent again after a lost answer, the same piece.
    // 0x7fffffff, not 1 << 32: on the web a shift is 32-bit.
    _requestKey ??= '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';
    setState(() => _saving = true);
    try {
      final saved = await _api.registerPiece({
        if (_isBatch(line)) 'coding_id': line['coding_id'] else 'line_id': line['line_id'],
        'weight': weight,
        'stones_weight': readTypedNumber(_stones.text) ?? 0,
        if (_model != null) 'model_id': _model!['id'],
        if (_sizeId != null) 'size_id': _sizeId,
        if (byPiece) ...{'wage': wage, 'wage_whole': _wageWhole},
        'request_key': _requestKey,
      });
      if (!mounted) return;
      final piece = saved['piece'] as Map<String, dynamic>;
      setState(() {
        _line = saved['line'] as Map<String, dynamic>;
        _pieces = [..._pieces.where((p) => p['id'] != piece['id']), piece];
        _last = piece;
        _requestKey = null;
        _saving = false;
        _weight.clear();
        _stones.clear();
        _wage.clear();
        _weighed = null;
      });
      _weightFocus.requestFocus();
      // Its label: a job of its own -- printed now, or waiting (ADR-097 law 1).
      _labels.print(context, piece, run: _autoPrint);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // Refused (400), nothing was saved: the next attempt is a new one.
        // Any other answer may hide a saved piece: the key kept.
        if (e.statusCode == 400) _requestKey = null;
      });
      AppFeedback.error(context, e);
    } catch (e) {
      // The answer lost: the key kept, sending again gives the same piece.
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('محطة ترميز القطع'),
          leading: line == null
              ? null
              : IconButton(
                  key: const Key('station-back'),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'أسطر الترميز',
                  onPressed: _close,
                ),
        ),
        body: Column(
          children: [
            _printerBar(context),
            Expanded(child: line == null ? _list(context) : _station(context, line)),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final pending = _pending;
    if (_error != null) {
      return AppErrorView(title: 'تعذّر تحميل أسطر الترميز', error: _error, onRetry: _loadPending);
    }
    if (pending == null) return const AppLoadingView();
    if (pending.isEmpty) {
      return AppEmptyView(
        title: 'لا سطر ينتظر الترميز',
        hint:
            'تظهر هنا أسطر الاستلام في التصنيفات المتتبَّعة بالقطعة، '
            'ودفعات الترميز من المخزون الموجود',
        icon: Icons.task_alt,
        actionLabel: 'ترميز من المخزون الموجود',
        actionIcon: Icons.inventory_outlined,
        onAction: _fromStock,
      );
    }
    return RefreshIndicator(
      onRefresh: _loadPending,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('station-from-stock'),
              onPressed: _fromStock,
              icon: const Icon(Icons.inventory_outlined),
              label: const Text('ترميز من المخزون الموجود'),
            ),
          ),
          const SizedBox(height: 8),
          for (final l in pending)
            Card(
              child: ListTile(
                key: Key(_isBatch(l) ? 'station-coding-${l['coding_id']}' : 'station-line-${l['line_id']}'),
                leading: Icon(_isBatch(l) ? Icons.inventory_outlined : Icons.qr_code_2),
                title: Text('${l['category_name'] ?? '-'} — ${_whence(l)}'),
                subtitle: Text('${l['invoice_number'] ?? ''}\n${_counter(l)}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_left),
                onTap: () => _open(l),
              ),
            ),
        ],
      ),
    );
  }

  /// A batch's pieces are each written their own wage (ADR-096 §4).
  static bool _wageByPiece(Map<String, dynamic> l) => l['wage_by_piece'] == true;

  /// From 2027's opening a batch's piece takes its pool's average (ADR-096
  /// ت3): shown where the wage was written, not asked.
  static bool _wageFromPool(Map<String, dynamic> l) => l['wage_from_pool'] == true;

  Widget _poolWage(Map<String, dynamic> l) {
    final perGram = l['pool_wage_per_gram'] as num?;
    return InputDecorator(
      key: const Key('piece-wage-from-pool'),
      decoration: const InputDecoration(labelText: 'الأجرة من الوعاء', helperText: 'بمتوسط أجور التصنيف'),
      child: Text(
        perGram == null ? 'لا أجرة في الوعاء' : '${formatAmount(perGram.toDouble())} للجرام',
        textDirection: perGram == null ? null : TextDirection.ltr,
      ),
    );
  }

  /// How the piece's wage is written: per gram or its whole -- kept for the
  /// next piece.
  Widget _wageKind() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: SegmentedButton<bool>(
        key: const Key('piece-wage-kind'),
        segments: const [
          ButtonSegment(value: false, label: Text('أجرة الجرام')),
          ButtonSegment(value: true, label: Text('أجرة القطعة كلها')),
        ],
        selected: {_wageWhole},
        onSelectionChanged: (v) => setState(() => _wageWhole = v.first),
      ),
    ),
  );

  /// The piece's wage, written after its weight, and the model's expected
  /// one under it -- a help, not a figure filled in.
  Widget _wageField() {
    final expected = _wageCheck?['expected_per_gram'] as num?;
    return TextField(
      key: const Key('piece-wage'),
      controller: _wage,
      focusNode: _wageFocus,
      textDirection: TextDirection.ltr,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: _wageWhole ? 'أجرة القطعة كلها' : 'أجرة الجرام',
        helperText: expected == null ? null : 'الموديل: ${formatAmount(expected.toDouble())} للجرام',
      ),
      onSubmitted: (_) => _register(),
    );
  }

  /// A receipt line's supplier, or a batch's location.
  static String _whence(Map<String, dynamic> l) => '${(_isBatch(l) ? l['safe_name'] : l['supplier_name']) ?? '-'}';

  String _counter(Map<String, dynamic> l) =>
      'الوزن ${_g(l['weight'])} جم · رُمّز ${l['pieces']} قطعة · الباقي ${_g(l['rest'])} جم';

  static String _g(Object? v) => formatGrams((v as num? ?? 0).toDouble(), decimals: 2);

  /// The line's model (optional) and the wage warning: the invoice's wage per
  /// gram against the model's expected one -- the piece keeps the invoice's.
  Widget _modelSection(BuildContext context) {
    final theme = Theme.of(context);
    final model = _model;
    final check = _wageCheck;
    final failedWords = _modelsFailed ? 'تعذّر تحميل الموديلات: القطعة تُسجَّل بلا موديل' : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // on a phone -- the reader -- one line (the owner, 22 Nov 2026): the weight, the field most used,
        // rises to the screen's upper half
        if (AppBreakpoints.isPhone(context))
          Card(
            child: Padding(
              key: const Key('station-model'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: ModelImage(api: _api, attachmentId: model?['thumbnail_id'] as int?),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'الموديل: ${model == null ? 'بلا موديل' : '${model['name']}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (_models.isNotEmpty)
                    TextButton(
                      key: const Key('station-model-change'),
                      onPressed: _chooseModel,
                      child: Text(model == null ? 'اختيار' : 'تغيير'),
                    ),
                ],
              ),
            ),
          )
        else
          Card(
            child: ListTile(
              key: const Key('station-model'),
              leading: SizedBox(
                width: 56,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ModelImage(api: _api, attachmentId: model?['thumbnail_id'] as int?),
                ),
              ),
              title: Text(model == null ? 'بلا موديل' : '${model['name']}'),
              subtitle: Text(
                failedWords ?? (_models.isEmpty ? 'لا موديلات لهذا التصنيف' : 'الموديل (اختياري)'),
              ),
              trailing: _models.isEmpty
                  ? null
                  : OutlinedButton(
                      key: const Key('station-model-change'),
                      onPressed: _chooseModel,
                      child: Text(model == null ? 'اختيار' : 'تغيير'),
                    ),
            ),
          ),
        if (failedWords != null && AppBreakpoints.isPhone(context))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(failedWords, style: theme.textTheme.bodySmall),
          ),
        if (check != null && check['state'] == 'model_wage_differs')
          Card(
            key: const Key('station-wage-differs'),
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onTertiaryContainer),
              title: Text(
                'أجرة الفاتورة تختلف عن الموديل',
                style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
              ),
              subtitle: Text(
                'الفاتورة ${formatAmount((check['invoice_per_gram'] as num).toDouble())} للجرام · '
                'الموديل ${formatAmount((check['expected_per_gram'] as num).toDouble())}. '
                'القطع تأخذ أجرة الفاتورة.',
                style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
              ),
            ),
          ),
        if (check != null && check['state'] == 'awaiting_invoice')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'أجرة الفاتورة لم تُكتب بعد. أجرة الموديل المتوقّعة '
              '${formatAmount((check['expected_per_gram'] as num).toDouble())} للجرام، وتُقارَن حين تُكمَل الفاتورة.',
              key: const Key('station-wage-awaiting'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// The weight -- the field the eye goes to -- the stones behind «+ فصوص»,
  /// the wage and the button: one row from a tablet up; on a phone the weight
  /// on its own line, the button full width.
  Widget _entry(BuildContext context, Map<String, dynamic> line) {
    final theme = Theme.of(context);
    final weight = TextField(
      key: const Key('piece-weight'),
      controller: _weight,
      focusNode: _weightFocus,
      autofocus: true,
      textDirection: TextDirection.ltr,
      style: theme.textTheme.headlineSmall,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: 'وزن القطعة (جم)', helperText: 'كما يقول الميزان'),
      onChanged: (_) => _askWeigh(),
      onSubmitted: (_) => _register(),
    );
    // Most pieces have none: the field opened once, kept open for the line.
    final stones = _stonesOpen || _stones.text.isNotEmpty
        ? TextField(
            key: const Key('piece-stones'),
            controller: _stones,
            focusNode: _stonesFocus,
            textDirection: TextDirection.ltr,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'وزن الفصوص (جم)'),
            onChanged: (_) => _askWeigh(),
            onSubmitted: (_) => _register(),
          )
        : null;
    final addStones = TextButton.icon(
      key: const Key('piece-stones-add'),
      onPressed: () {
        setState(() => _stonesOpen = true);
        WidgetsBinding.instance.addPostFrameCallback((_) => _stonesFocus.requestFocus());
      },
      icon: const Icon(Icons.add),
      label: const Text('فصوص'),
    );
    final wage = _wageByPiece(line)
        ? _wageField()
        : _wageFromPool(line)
        ? _poolWage(line)
        : null;
    final button = FilledButton.icon(
      key: const Key('piece-register'),
      onPressed: _saving ? null : _register,
      icon: const Icon(Icons.qr_code),
      label: const Text('تسجيل القطعة'),
    );
    if (AppBreakpoints.isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          weight,
          const SizedBox(height: 8),
          if (stones != null || wage != null)
            Row(
              children: [
                if (stones != null) Expanded(child: stones),
                if (stones != null && wage != null) const SizedBox(width: 12),
                if (wage != null) Expanded(child: wage),
              ],
            ),
          if (stones == null) Align(alignment: AlignmentDirectional.centerStart, child: addStones),
          const SizedBox(height: 12),
          button,
        ],
      );
    }
    return Row(
      children: [
        Expanded(flex: 2, child: weight),
        const SizedBox(width: 12),
        if (stones != null) Expanded(child: stones) else addStones,
        if (wage != null) ...[const SizedBox(width: 12), Expanded(child: wage)],
        const SizedBox(width: 12),
        button,
      ],
    );
  }

  /// The weight typed, asked of the server a moment after the last key: the
  /// newest answer kept, an older one arriving late dropped.
  void _askWeigh() {
    _weighTimer?.cancel();
    final line = _line;
    final weight = readTypedNumber(_weight.text) ?? 0;
    if (line == null || weight <= 0) {
      if (_weighed != null) setState(() => _weighed = null);
      return;
    }
    _weighTimer = Timer(weighAfter, () async {
      final asked = ++_weighAsked;
      try {
        final answer = await _api.weighPiece(
          lineId: _isBatch(line) ? null : line['line_id'] as int?,
          codingId: _isBatch(line) ? line['coding_id'] as int? : null,
          weight: weight,
          stonesWeight: readTypedNumber(_stones.text) ?? 0,
        );
        if (mounted && asked == _weighAsked && _line == line) setState(() => _weighed = answer);
      } catch (_) {
        // a help: without it the piece is still registered, and refused there if it must be
        if (mounted && asked == _weighAsked) setState(() => _weighed = null);
      }
    });
  }

  /// The server's reading of the weight typed, under the entry: the piece's
  /// net, its stones and how they count, the rest after it -- or the refusal.
  Widget _weighedLine(BuildContext context) {
    final theme = Theme.of(context);
    final answer = _weighed;
    if (answer == null) return const SizedBox.shrink();
    final refused = answer['refused'] as Map<String, dynamic>?;
    final w = answer['weighed'] as Map<String, dynamic>?;
    if (refused == null && w == null) return const SizedBox.shrink();
    final tones = AppSemanticColors.of(context);
    final words = refused != null
        ? '${refused['message']}'
        : [
            'الوزن ${_g(w!['grams'])} جم',
            if (((w['stones_weight'] as num?) ?? 0) > 0) _stonesWords(w['stones_weight'], w['stones_kind']),
            'يبقى ${_g(w['rest_after'])} جم',
          ].join(' · ');
    final tone = refused != null ? tones.blocked : tones.info;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(refused != null ? Icons.error_outline : Icons.scale_outlined, size: 18, color: tone.fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              words,
              key: const Key('station-weighed'),
              style: theme.textTheme.bodyMedium?.copyWith(color: tone.fg, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// A piece's facts in one line: its weight, its stones, its size, its model.
  /// Its weight -- its grams in the books, what is sold as gold -- its stones
  /// beside it: within it, or «+» out of it when priced apart (the owner,
  /// 20 Nov 2026).
  static String _facts(Map<String, dynamic> p) => [
    '${_g(p['weight'])} جم',
    if (((p['stones_weight'] as num?) ?? 0) > 0) _stonesWords(p['stones_weight'], p['stones_kind']),
    if (p['size'] != null) 'مقاس ${(p['size'] as Map)['label']}',
    if (p['model'] != null) '${(p['model'] as Map)['name']}',
  ].join(' · ');

  /// Stones counted as gold are within the weight; priced apart, added to it.
  static String _stonesWords(Object? stones, Object? kind) =>
      kind == 'priced' ? '+ فصوص ${_g(stones)} جم' : 'فصوص ${_g(stones)} جم ضمن الوزن';

  static String _wageWords(Map<String, dynamic> p) =>
      p['wage_known'] == true ? 'الأجرة ${formatAmount((p['wage'] as num).toDouble())}' : 'بانتظار الفاتورة';

  /// The last attempt's three steps, each its own (ADR-097): printed, its tag
  /// written, read back. Not yet known is said as such, never as done.
  Widget _steps(BuildContext context, Map<String, dynamic> label) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    Widget step(String word, Object? done) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          done == true ? Icons.check_circle : (done == false ? Icons.cancel : Icons.remove_circle_outline),
          size: 18,
          color: done == true ? tones.ready.fg : (done == false ? tones.blocked.fg : theme.colorScheme.outline),
        ),
        const SizedBox(width: 4),
        Text(word, style: theme.textTheme.bodySmall),
      ],
    );
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        step('طُبعت', label['printed']),
        step('كُتبت الرقاقة', label['written']),
        step('قُرئت وطابقت', label['verified']),
      ],
    );
  }

  /// Zone 2: the line -- what it is, and how far it is coded.
  Widget _lineCard(BuildContext context, Map<String, dynamic> line) {
    final theme = Theme.of(context);
    final weight = (line['weight'] as num? ?? 0).toDouble();
    final coded = (line['pieces_weight'] as num? ?? 0).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${line['category_name'] ?? '-'} · عيار ${line['karat']}', style: theme.textTheme.titleMedium),
            Text('${_whence(line)} — ${line['invoice_number'] ?? ''}', style: theme.textTheme.bodySmall),
            if (line['stones_kind'] == 'priced') ...[
              const SizedBox(height: 6),
              Text(
                'فصوص هذا السطر مسعَّرة بالقيراط: خارج ذهبه، فوزن القطعة صافيها والفصوص تُضاف عليه.',
                key: const Key('station-stones-priced'),
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                key: const Key('station-progress'),
                value: weight > 0 ? (coded / weight).clamp(0.0, 1.0) : 0,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'رُمّز ${_g(coded)} من ${_g(weight)} جم · ${line['pieces']} قطعة · الباقي ${_g(line['rest'])} جم',
              key: const Key('station-counter'),
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
      ),
    );
  }

  /// Zone 3's side: the piece just registered -- its number, its facts, its
  /// label's state in full, its one action, and its label as it prints.
  Widget _currentCard(BuildContext context) {
    final theme = Theme.of(context);
    final last = _last;
    if (last == null) {
      return Card(
        key: const Key('station-current-empty'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.qr_code_2, size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 8),
              Text('القطعة الحالية', style: theme.textTheme.titleSmall),
              Text(
                'سجّل قطعة: تظهر هنا مع حالة بطاقتها ومعاينتها.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final label = last['label'] as Map<String, dynamic>?;
    final look = LabelLook.of(last);
    final message = look == LabelLook.done ? null : (label?['printer_message'] ?? label?['message']);
    return Card(
      key: const Key('station-last'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // a Wrap: on a phone its state goes under its number, never squeezing it
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${last['item_code']}',
                  key: const Key('station-last-code'),
                  textDirection: TextDirection.ltr,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                LabelBadge(piece: last, large: true),
              ],
            ),
            Text(_facts(last), style: theme.textTheme.bodyMedium),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text('$message', key: const Key('station-last-message'), style: theme.textTheme.bodyMedium),
            ],
            if (label?['attempt_id'] != null) ...[const SizedBox(height: 8), _steps(context, label!)],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: PieceLabelCell(
                piece: last,
                busy: _printing.contains(last['id']),
                actions: _labels,
                showState: false,
              ),
            ),
            // its label as it prints, both faces (ADR-097 ط5)
            Center(
              child: PieceLabelPreview(api: _api, pieceId: last['id'] as int),
            ),
          ],
        ),
      ),
    );
  }

  /// Zone 4: a row of the log -- its label's state and its one action at its
  /// side from a tablet up, under its words on a phone; its details on a tap.
  Widget _logRow(BuildContext context, Map<String, dynamic> p) {
    final cell = PieceLabelCell(piece: p, busy: _printing.contains(p['id']), actions: _labels);
    final title = Text('${p['item_code']}', textDirection: TextDirection.ltr, textAlign: TextAlign.right);
    final subtitle = Text('${_facts(p)} · ${_wageWords(p)}');
    void open() => _details(p);
    if (!AppBreakpoints.isPhone(context)) {
      return ListTile(
        key: Key('station-piece-${p['id']}'),
        dense: true,
        title: title,
        subtitle: subtitle,
        trailing: cell,
        onTap: open,
      );
    }
    return Column(
      key: Key('station-piece-${p['id']}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(dense: true, title: title, subtitle: subtitle, onTap: open),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 16, bottom: 8),
          child: Align(alignment: AlignmentDirectional.centerEnd, child: cell),
        ),
      ],
    );
  }

  /// A piece's details: its facts and its label's -- which print, which
  /// generation, the three steps of its last attempt, and what it said.
  Future<void> _details(Map<String, dynamic> p) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final label = p['label'] as Map<String, dynamic>?;
        Widget fact(String name, String value, {bool ltr = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text(name, style: theme.textTheme.bodyMedium)),
              Text(
                value,
                textDirection: ltr ? TextDirection.ltr : null,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        );
        final message = label?['printer_message'] ?? label?['message'];
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SingleChildScrollView(
              key: Key('piece-details-${p['id']}'),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${p['item_code']}', textDirection: TextDirection.ltr, style: theme.textTheme.titleLarge),
                      LabelBadge(piece: p, large: true),
                    ],
                  ),
                  const SizedBox(height: 8),
                  fact('الوزن', '${_g(p['weight'])} جم'),
                  if (((p['stones_weight'] as num?) ?? 0) > 0) ...[
                    fact('الفصوص', _stonesWords(p['stones_weight'], p['stones_kind'])),
                    if (p['stones_kind'] == 'priced' && p['standing_weight'] != null)
                      fact('القائم على الميزان', '${_g(p['standing_weight'])} جم'),
                    if (p['stones_kind'] != 'priced' && p['net_weight'] != null)
                      fact('ذهبها وحده', '${_g(p['net_weight'])} جم'),
                  ],
                  if (p['size'] != null) fact('المقاس', '${(p['size'] as Map)['label']}'),
                  if (p['model'] != null) fact('الموديل', '${(p['model'] as Map)['name']}'),
                  fact(
                    'الأجرة',
                    p['wage_known'] == true ? formatAmount((p['wage'] as num).toDouble()) : 'بانتظار الفاتورة',
                  ),
                  const Divider(height: 24),
                  Text('البطاقة', style: theme.textTheme.titleSmall),
                  if (label == null)
                    Text(p['tag'] != null ? 'رقاقة معتمدة قبل سجلّ الطباعة' : 'لم تُطلب لها بطاقة بعد')
                  else ...[
                    fact('الطلب', label['kind'] == 'reprint' ? 'إعادة طباعة' : 'الطباعة الأولى'),
                    if (label['generation'] != null) fact('الجيل', '${label['generation']}', ltr: true),
                    if (label['attempt_id'] != null) ...[const SizedBox(height: 4), _steps(sheet, label)],
                    if (message != null) ...[const SizedBox(height: 8), Text('$message')],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The station: the line, the work and the piece just registered, the log
  /// -- at a width the eye can follow on a wide screen.
  Widget _station(BuildContext context, Map<String, dynamic> line) {
    final theme = Theme.of(context);
    final rest = (line['rest'] as num? ?? 0).toDouble();
    final work = rest > 0.0005
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _modelSection(context),
              if (_offeredSizes.isNotEmpty) ...[
                Text('المقاس', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in _offeredSizes)
                      ChoiceChip(
                        key: Key('station-size-${s['id']}'),
                        selected: _sizeId == s['id'],
                        label: Text('${s['label']}', textDirection: TextDirection.ltr),
                        onSelected: (on) => setState(() => _sizeId = on ? s['id'] as int : null),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (_wageByPiece(line)) _wageKind(),
              _current(context),
              _entry(context, line),
              _weighedLine(context),
            ],
          )
        : const AppEmptyView(title: 'رُمّز السطر كله', icon: Icons.task_alt);
    final wide = AppBreakpoints.of(context) == DeviceClass.wide;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _lineCard(context, line),
            const SizedBox(height: 12),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: work),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: _currentCard(context)),
                ],
              )
            else ...[
              work,
              const SizedBox(height: 16),
              _currentCard(context),
            ],
            const SizedBox(height: 16),
            Text('قطع السطر (${_pieces.length})', style: theme.textTheme.titleSmall),
            for (final p in _pieces.reversed) _logRow(context, p),
          ],
        ),
      ),
    );
  }
}

/// A batch of a location's stock to code (R3.5): the location, the category
/// tracked by the piece, what it holds not yet coded (the server's) and the
/// weight to code. No wage: each piece is written its own (ADR-096 §4).
/// Returns the request's body.
class _FromStockDialog extends StatefulWidget {
  const _FromStockDialog({required this.api});
  final ApiService api;

  @override
  State<_FromStockDialog> createState() => _FromStockDialogState();
}

class _FromStockDialogState extends State<_FromStockDialog> {
  List<SafeBoxModel>? _safes;
  List<Category> _categories = const [];
  Object? _error;
  int? _safeId;
  int? _categoryId;
  double? _room;
  bool _wageFromPool = false;
  String? _problem;

  final _weight = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _weight.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final safes = await widget.api.getSafeBoxes(safeType: 'gold', isActive: true);
      final categories = await widget.api.getCategories();
      if (!mounted) return;
      setState(() {
        // an office's deposit is its gold, not ours to code (ADR-052)
        _safes = safes.where((s) => s.id != null && s.stockLocation != null && s.stockLocation != 'deposit').toList();
        _categories = categories
            .whereType<Map<String, dynamic>>()
            .map(Category.fromJson)
            .where((c) => c.id != null && c.isActive && !c.isScrap && c.byThePiece)
            .toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _readRoom() async {
    final safe = _safeId, category = _categoryId;
    setState(() => _room = null);
    if (safe == null || category == null) return;
    try {
      final room = await widget.api.stockCodingRoom(safe, category);
      if (mounted) {
        setState(() {
          _room = (room['room'] as num?)?.toDouble();
          _wageFromPool = room['wage_from_pool'] == true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _problem = AppFeedback.messageOf(e));
    }
  }

  void _submit() {
    final weight = readTypedNumber(_weight.text) ?? 0;
    if (_safeId == null || _categoryId == null) {
      setState(() => _problem = 'اختر الموقع والتصنيف');
    } else if (weight <= 0) {
      setState(() => _problem = 'أدخل وزن الدفعة');
    } else {
      Navigator.of(context).pop(<String, dynamic>{
        'safe_box_id': _safeId,
        'category_id': _categoryId,
        'weight': weight,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final safes = _safes;
    return AlertDialog(
      title: const Text('ترميز من المخزون الموجود'),
      content: SizedBox(
        width: 420,
        child: _error != null
            ? AppErrorView(title: 'تعذّر تحميل المواقع والتصنيفات', error: _error, onRetry: _load)
            : safes == null
            ? const AppLoadingView()
            : _categories.isEmpty
            ? const AppEmptyView(
                title: 'لا تصنيف يُتتبَّع بالقطعة',
                hint: 'اجعل التصنيف «بالقطعة» من تعديل التصنيف أولًا',
                icon: Icons.category_outlined,
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<int>(
                      key: const Key('coding-safe'),
                      initialValue: _safeId,
                      decoration: const InputDecoration(labelText: 'الموقع'),
                      items: [for (final s in safes) DropdownMenuItem(value: s.id, child: Text(s.name))],
                      onChanged: (v) {
                        setState(() => _safeId = v);
                        _readRoom();
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      key: const Key('coding-category'),
                      initialValue: _categoryId,
                      decoration: const InputDecoration(labelText: 'التصنيف'),
                      items: [for (final c in _categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                      onChanged: (v) {
                        setState(() => _categoryId = v);
                        _readRoom();
                      },
                    ),
                    if (_room != null) ...[
                      const SizedBox(height: 8),
                      Text('المتاح للترميز: ${formatGrams(_room!, decimals: 2)} جم', key: const Key('coding-room')),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('coding-weight'),
                      controller: _weight,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'وزن الدفعة (جم)'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _wageFromPool
                          ? 'لا أجرة للدفعة: كل قطعة تأخذ متوسط أجور تصنيفها.'
                          : 'لا أجرة للدفعة: تُكتب أجرة كل قطعة عند تسجيلها.',
                      key: const Key('coding-wage-by-piece'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('coding-note'),
                      controller: _note,
                      decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'),
                    ),
                    if (_problem != null) ...[
                      const SizedBox(height: 8),
                      Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('إلغاء')),
        FilledButton(
          key: const Key('coding-open'),
          onPressed: _categories.isEmpty ? null : _submit,
          child: const Text('فتح الدفعة'),
        ),
      ],
    );
  }
}
