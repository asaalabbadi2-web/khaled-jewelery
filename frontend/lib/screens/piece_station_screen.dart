import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/category_model.dart';
import '../models/safe_box_model.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import '../widgets/inline_number_cell.dart' show readTypedNumber;
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

  final _weight = TextEditingController();
  final _stones = TextEditingController();
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
  }

  @override
  void dispose() {
    _weight.dispose();
    _stones.dispose();
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

  static String _key() =>
      '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';

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

  /// A job as the piece carries it: its state and its last attempt's.
  static Map<String, dynamic> _labelOf(Map<String, dynamic> job) {
    final last = job['last_attempt'] as Map<String, dynamic>?;
    return {
      'job_id': job['id'], 'kind': job['kind'], 'status': job['status'],
      'attempt_id': last?['id'], 'generation': last?['generation'],
      'printed': last?['printed'], 'written': last?['written'], 'verified': last?['verified'],
      'message': last?['message'],
    };
  }

  void _setLabel(int pieceId, Map<String, dynamic> label) {
    Map<String, dynamic> withIt(Map<String, dynamic> p) =>
        p['id'] == pieceId ? {...p, 'label': label} : p;
    setState(() {
      _pieces = [for (final p in _pieces) withIt(p)];
      if (_last != null) _last = withIt(_last!);
    });
  }

  /// One job through the engine -- the first print, «تسجيل فقط» (run false),
  /// a reprint with its reason. The piece is saved before: a printer that
  /// fails stops no one.
  Future<void> _printPiece(Map<String, dynamic> p, {String kind = 'first', String? reason,
      bool run = true}) async {
    final id = p['id'] as int;
    setState(() => _printing.add(id));
    try {
      final saved = await _api.printPieceLabel(id, {
        'request_key': _key(),
        'kind': kind,
        if (reason != null) 'reason': reason,
        'run': run,
      });
      if (!mounted) return;
      final label = _labelOf(saved['job'] as Map<String, dynamic>);
      _setLabel(id, label);
      if (run && label['status'] != 'completed') {
        AppFeedback.warning(context,
            'تم تسجيل القطعة بنجاح، لكن تعذّرت طباعة البطاقة. أُضيفت إلى قائمة انتظار الطباعة.');
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.warning(context,
            'تم تسجيل القطعة بنجاح، لكن تعذّرت طباعة البطاقة. أُضيفت إلى قائمة انتظار الطباعة.');
      }
    } finally {
      if (mounted) setState(() => _printing.remove(id));
      _refreshQueue();
      _loadPrinterState();
    }
  }

  Future<void> _loadPrinterState() async {
    if (_printerId == null) return;
    try {
      final state = await _api.labelPrinterStatus(_printerId!);
      if (mounted) setState(() => _printerState = state['status'] as Map<String, dynamic>?);
    } catch (_) {}
  }

  /// A failed or waiting job run again: a new attempt, a new generation.
  Future<void> _retry(int pieceId, int jobId) async {
    setState(() => _printing.add(pieceId));
    try {
      final saved = await _api.runPrintJob(jobId);
      if (mounted) _setLabel(pieceId, _labelOf(saved['job'] as Map<String, dynamic>));
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _printing.remove(pieceId));
      _refreshQueue();
      _loadPrinterState();
    }
  }

  /// An attempt whose end is not known: the label read by the reader, or
  /// none came out (ADR-097 law 10).
  Future<void> _resolve(int pieceId, String code, int attemptId) async {
    final answer = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ResolveDialog(code: code),
    );
    if (answer == null || !mounted) return;
    try {
      final saved = await _api.resolvePrintAttempt(attemptId, answer);
      if (mounted) _setLabel(pieceId, _labelOf(saved['job'] as Map<String, dynamic>));
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      _refreshQueue();
    }
  }

  /// A new label for a piece whose label is adopted: its reason asked; the
  /// old tag stopped once the new one is read back (ADR-097 law 4).
  Future<void> _reprint(Map<String, dynamic> p) async {
    final reason = await confirmFinancialAction(
      context,
      title: 'إعادة طباعة بطاقة ${p['item_code']}؟',
      effect: 'تُطبع بطاقة جديدة برقاقة جديدة، وتُلغى القديمة حين تُعتمد الجديدة. رقم القطعة لا يتغيّر.',
      confirmLabel: 'إعادة الطباعة',
      reasonLabel: 'سبب إعادة الطباعة',
      destructive: false,
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    await _printPiece(p, kind: 'reprint', reason: reason.trim());
  }

  /// Its label's state and what can be done -- one widget, in the last
  /// piece's card and in the line's list.
  Widget _labelCell(Map<String, dynamic> p) {
    final id = p['id'] as int;
    final label = p['label'] as Map<String, dynamic>?;
    if (_printing.contains(id)) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final status = label?['status'] as String?;
    Widget action(String key, String text, IconData icon, VoidCallback onPressed) =>
        TextButton.icon(key: Key('$key-$id'), onPressed: onPressed, icon: Icon(icon), label: Text(text));
    switch (status) {
      case 'completed':
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Text('مطبوعة · الجيل ${label!['generation']}', key: Key('label-done-$id')),
          action('label-reprint', 'إعادة الطباعة', Icons.print_outlined, () => _reprint(p)),
        ]);
      case 'failed':
        return action('label-retry', 'إعادة المحاولة', Icons.refresh, () => _retry(id, label!['job_id'] as int));
      case 'needs_attention':
        return action('label-resolve', 'حسم المحاولة', Icons.help_outline,
            () => _resolve(id, '${p['item_code']}', label!['attempt_id'] as int));
      case 'pending':
      case 'printing':
      case 'verifying':
        return action('label-run', 'اطبع الآن', Icons.print, () => _retry(id, label!['job_id'] as int));
      default:
        return action('label-print', 'اطبع البطاقة', Icons.print, () => _printPiece(p));
    }
  }

  /// The printer and the labels waiting -- one line above the station.
  Widget _printerBar(BuildContext context) {
    final theme = Theme.of(context);
    final state = _printerState;
    final ready = state?['ready'] == true;
    final pending = (_queueCounts['pending'] as num?)?.toInt() ?? 0;
    final failed = ((_queueCounts['failed'] as num?)?.toInt() ?? 0) +
        ((_queueCounts['needs_attention'] as num?)?.toInt() ?? 0);
    final text = _printerId == null
        ? 'لا طابعة بطاقات مفعّلة'
        : state == null
            ? 'حالة الطابعة غير معروفة'
            : ready
                ? 'الطابعة جاهزة'
                : '${state['message'] ?? 'الطابعة متوقفة'}';
    return Material(
      color: ready ? theme.colorScheme.secondaryContainer : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(ready ? Icons.print : Icons.print_disabled,
                color: ready ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                key: const Key('station-printer'),
                style: TextStyle(
                    color: ready ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onErrorContainer),
              ),
            ),
            Text('بانتظار البطاقة $pending · فاشلة $failed', key: const Key('station-queue')),
            if (failed > 0) ...[
              const SizedBox(width: 8),
              TextButton(
                key: const Key('station-failures'),
                onPressed: _failures,
                child: const Text('معالجة الفشل'),
              ),
            ],
            IconButton(
              key: const Key('station-printer-refresh'),
              tooltip: 'سؤال الطابعة',
              icon: const Icon(Icons.refresh),
              onPressed: _loadPrinter,
            ),
          ],
        ),
      ),
    );
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
                          _retry(j['item_id'] as int, j['id'] as int);
                        },
                        child: const Text('إعادة المحاولة'))
                    : TextButton(
                        onPressed: () {
                          Navigator.of(sheet).pop();
                          _resolve(j['item_id'] as int, '${j['item_code']}',
                              (j['last_attempt'] as Map)['id'] as int);
                        },
                        child: const Text('حسم المحاولة')),
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
    final byPiece = _wageByPiece(line);
    final wage = byPiece ? readTypedNumber(_wage.text) : null;
    if (byPiece && (wage == null || wage < 0)) {
      AppFeedback.warning(context, 'أدخل أجرة القطعة: صفر أو أكثر');
      _wageFocus.requestFocus();
      return;
    }
    // One attempt, one key: sent again after a lost answer, the same piece.
    // 0x7fffffff, not 1 << 32: on the web a shift is 32-bit.
    _requestKey ??=
        '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';
    setState(() => _saving = true);
    try {
      final saved = await _api.registerPiece({
        if (_isBatch(line))
          'coding_id': line['coding_id']
        else
          'line_id': line['line_id'],
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
      });
      _weightFocus.requestFocus();
      // Its label: a job of its own -- printed now, or waiting (ADR-097 law 1).
      _printPiece(piece, run: _autoPrint);
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
      return AppErrorView(
        title: 'تعذّر تحميل أسطر الترميز',
        error: _error,
        onRetry: _loadPending,
      );
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
                key: Key(
                  _isBatch(l)
                      ? 'station-coding-${l['coding_id']}'
                      : 'station-line-${l['line_id']}',
                ),
                leading: Icon(
                  _isBatch(l) ? Icons.inventory_outlined : Icons.qr_code_2,
                ),
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
      decoration: const InputDecoration(
        labelText: 'الأجرة من الوعاء',
        helperText: 'بمتوسط أجور التصنيف',
      ),
      child: Text(
        perGram == null
            ? 'لا أجرة في الوعاء'
            : '${formatAmount(perGram.toDouble())} للجرام',
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
        helperText: expected == null
            ? null
            : 'الموديل: ${formatAmount(expected.toDouble())} للجرام',
      ),
      onSubmitted: (_) => _register(),
    );
  }

  /// A receipt line's supplier, or a batch's location.
  static String _whence(Map<String, dynamic> l) =>
      '${(_isBatch(l) ? l['safe_name'] : l['supplier_name']) ?? '-'}';

  String _counter(Map<String, dynamic> l) =>
      'الوزن ${_g(l['weight'])} جم · رُمّز ${l['pieces']} قطعة · الباقي ${_g(l['rest'])} جم';

  static String _g(Object? v) =>
      formatGrams((v as num? ?? 0).toDouble(), decimals: 2);

  /// The line's model (optional) and the wage warning: the invoice's wage per
  /// gram against the model's expected one -- the piece keeps the invoice's.
  Widget _modelSection(BuildContext context) {
    final theme = Theme.of(context);
    final model = _model;
    final check = _wageCheck;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              _modelsFailed
                  ? 'تعذّر تحميل الموديلات: القطعة تُسجَّل بلا موديل'
                  : _models.isEmpty
                      ? 'لا موديلات لهذا التصنيف'
                      : 'الموديل (اختياري)',
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

  Widget _station(BuildContext context, Map<String, dynamic> line) {
    final theme = Theme.of(context);
    final rest = (line['rest'] as num? ?? 0).toDouble();
    final last = _last;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            title: Text(
              '${line['category_name'] ?? '-'} · عيار ${line['karat']}',
              style: theme.textTheme.titleMedium,
            ),
            subtitle: Text(
              '${_whence(line)} — ${line['invoice_number'] ?? ''}\n${_counter(line)}',
              key: const Key('station-counter'),
            ),
            isThreeLine: true,
          ),
        ),
        const SizedBox(height: 12),
        _modelSection(context),
        if (rest > 0.0005) ...[
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
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: SegmentedButton<bool>(
                key: const Key('station-print-mode'),
                segments: const [
                  ButtonSegment(value: true, label: Text('طباعة تلقائية'), icon: Icon(Icons.print)),
                  ButtonSegment(value: false, label: Text('تسجيل فقط'), icon: Icon(Icons.save_outlined)),
                ],
                selected: {_autoPrint},
                onSelectionChanged: (v) => setState(() => _autoPrint = v.first),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('piece-weight'),
                  controller: _weight,
                  focusNode: _weightFocus,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'وزن القطعة (جم)',
                  ),
                  onSubmitted: (_) => _register(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const Key('piece-stones'),
                  controller: _stones,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'وزن الفصوص (جم)',
                  ),
                  onSubmitted: (_) => _register(),
                ),
              ),
              if (_wageByPiece(line)) ...[
                const SizedBox(width: 12),
                Expanded(child: _wageField()),
              ] else if (_wageFromPool(line)) ...[
                const SizedBox(width: 12),
                Expanded(child: _poolWage(line)),
              ],
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('piece-register'),
                onPressed: _saving ? null : _register,
                icon: const Icon(Icons.qr_code),
                label: const Text('تسجيل القطعة'),
              ),
            ],
          ),
        ] else
          const AppEmptyView(title: 'رُمّز السطر كله', icon: Icons.task_alt),
        if (last != null) ...[
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.primaryContainer,
            child: ListTile(
              key: const Key('station-last'),
              leading: const Icon(Icons.sell_outlined),
              title: Text(
                '${last['item_code']}',
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.right,
                style: theme.textTheme.headlineSmall,
              ),
              subtitle: Text(
                '${_g(last['weight'])} جم'
                '${(last['label'] as Map?)?['message'] == null ? '' : '\n${(last['label'] as Map)['message']}'}',
              ),
              trailing: _labelCell(last),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'قطع السطر (${_pieces.length})',
          style: theme.textTheme.titleSmall,
        ),
        for (final p in _pieces.reversed)
          ListTile(
            key: Key('station-piece-${p['id']}'),
            dense: true,
            title: Text(
              '${p['item_code']}',
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.right,
            ),
            subtitle: Text(
              '${_g(p['weight'])} جم'
              '${((p['stones_weight'] as num?) ?? 0) > 0 ? ' · فصوص ${_g(p['stones_weight'])} جم' : ''}'
              '${p['size'] == null ? '' : ' · مقاس ${(p['size'] as Map)['label']}'}'
              '${p['model'] == null ? '' : ' · ${(p['model'] as Map)['name']}'}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  p['wage_known'] == true
                      ? 'الأجرة ${formatAmount((p['wage'] as num).toDouble())}'
                      : 'بانتظار الفاتورة',
                ),
                const SizedBox(width: 8),
                // Its label (ADR-097): printed through the engine, its tag
                // adopted only read back; a reprint with its reason.
                _labelCell(p),
              ],
            ),
          ),
      ],
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
      final safes = await widget.api.getSafeBoxes(
        safeType: 'gold',
        isActive: true,
      );
      final categories = await widget.api.getCategories();
      if (!mounted) return;
      setState(() {
        // an office's deposit is its gold, not ours to code (ADR-052)
        _safes = safes
            .where(
              (s) =>
                  s.id != null &&
                  s.stockLocation != null &&
                  s.stockLocation != 'deposit',
            )
            .toList();
        _categories = categories
            .whereType<Map<String, dynamic>>()
            .map(Category.fromJson)
            .where(
              (c) => c.id != null && c.isActive && !c.isScrap && c.byThePiece,
            )
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
            ? AppErrorView(
                title: 'تعذّر تحميل المواقع والتصنيفات',
                error: _error,
                onRetry: _load,
              )
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
                      items: [
                        for (final s in safes)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
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
                      items: [
                        for (final c in _categories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) {
                        setState(() => _categoryId = v);
                        _readRoom();
                      },
                    ),
                    if (_room != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'المتاح للترميز: ${formatGrams(_room!, decimals: 2)} جم',
                        key: const Key('coding-room'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('coding-weight'),
                      controller: _weight,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'وزن الدفعة (جم)',
                      ),
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
                      decoration: const InputDecoration(
                        labelText: 'ملاحظة (اختياري)',
                      ),
                    ),
                    if (_problem != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _problem!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          key: const Key('coding-open'),
          onPressed: _categories.isEmpty ? null : _submit,
          child: const Text('فتح الدفعة'),
        ),
      ],
    );
  }
}

/// An attempt whose end is not known (ADR-097 law 10): the label that came
/// out read by the handheld reader -- it types the tag's value into the field
/// -- or no label came out. Returns the request's body.
class _ResolveDialog extends StatefulWidget {
  const _ResolveDialog({required this.code});
  final String code;

  @override
  State<_ResolveDialog> createState() => _ResolveDialogState();
}

class _ResolveDialogState extends State<_ResolveDialog> {
  final _read = TextEditingController();

  @override
  void dispose() {
    _read.dispose();
    super.dispose();
  }

  void _adopt() {
    final value = _read.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop({'read_value': value});
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('بطاقة ${widget.code}: هل خرج ملصق؟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('انقطع الاتصال بالطابعة ولا يُعرف هل كُتبت الرقاقة. '
                'إن خرج ملصق فاقرأه بالقارئ هنا، وإلا اضغط «لم يخرج ملصق».'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('resolve-read'),
              controller: _read,
              autofocus: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'رمز الرقاقة من القارئ'),
              onSubmitted: (_) => _adopt(),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('resolve-no-label'),
            onPressed: () => Navigator.of(context).pop({'no_label': true}),
            child: const Text('لم يخرج ملصق'),
          ),
          FilledButton(
            key: const Key('resolve-adopt'),
            onPressed: _adopt,
            child: const Text('اعتمد القراءة'),
          ),
        ],
      ),
    );
  }
}
