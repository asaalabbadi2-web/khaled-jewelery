import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/piece_scan_result.dart';
import '../widgets/reader_capture.dart';

/// «جرد بالمسح» on the handheld reader (ADR-085 ت2 ج1; the owner, 21 Nov 2026).
///
/// A location, its kind, its scope -- a section, a category, or every piece --
/// then the reader passed over every place the pieces are shown, its button
/// held or pressed. What the reader sends ([ReaderCapture]) goes to the server
/// in batches, each once by its key; every verdict and every figure is the
/// server's. Nothing finishes by itself: «إنهاء الجرد» waits for the server's
/// «complete» -- no new tag in the last presses -- and before it only an early
/// finish with its reason, said so in the scan's log.
class PieceScanScreen extends StatefulWidget {
  const PieceScanScreen({super.key, this.api, this.elapsed, this.sendEvery = const Duration(milliseconds: 400)});
  final ApiService? api;

  /// Milliseconds on the reader -- a stopwatch unless given (a test's).
  final int Function()? elapsed;

  /// How often what the reader sent goes to the server.
  final Duration sendEvery;

  @override
  State<PieceScanScreen> createState() => _PieceScanScreenState();
}

class _PieceScanScreenState extends State<PieceScanScreen> {
  late final ApiService _api = widget.api ?? ApiService();

  // ── the start ──
  List<Map<String, dynamic>>? _locations;
  List<Map<String, dynamic>> _sections = const [];
  List<Map<String, dynamic>> _categories = const [];
  List<Map<String, dynamic>> _open = const [];
  Object? _error;
  int? _locationId;
  String _kind = 'check';
  String _scopeKind = 'all';
  int? _sectionId;
  int? _categoryId;
  bool _starting = false;

  // ── the scan ──
  Map<String, dynamic>? _scan;
  ReaderCapture? _capture;
  final _focus = FocusNode();
  final List<Map<String, dynamic>> _waiting = [];
  ({String key, List<Map<String, dynamic>> events})? _sending;
  Timer? _sendTimer;
  bool _offline = false;
  bool _finishing = false;

  static const kinds = {'opening': 'جرد فتح', 'closing': 'جرد إغلاق', 'check': 'تحقّق'};

  @override
  void initState() {
    super.initState();
    _loadStart();
  }

  @override
  void dispose() {
    _sendTimer?.cancel();
    _capture?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadStart() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([
        _api.pieceScanLocations(),
        _api.itemSections(),
        _api.getCategories(),
        _api.openPieceScans(),
      ]);
      if (!mounted) return;
      setState(() {
        _locations = ((results[0] as Map)['locations'] as List? ?? []).cast<Map<String, dynamic>>();
        _sections = ((results[1] as Map)['sections'] as List? ?? [])
            .cast<Map<String, dynamic>>()
            .where((s) => s['is_active'] != false)
            .toList();
        _categories = (results[2] as List)
            .cast<Map<String, dynamic>>()
            .where((c) => c['is_scrap'] != true)
            .toList();
        _open = ((results[3] as Map)['scans'] as List? ?? []).cast<Map<String, dynamic>>();
        _locationId ??= _locations!.isEmpty ? null : _locations!.first['id'] as int;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _start() async {
    if (_locationId == null) return;
    if (_scopeKind == 'section' && _sectionId == null || _scopeKind == 'category' && _categoryId == null) {
      AppFeedback.warning(context, _scopeKind == 'section' ? 'اختر القسم' : 'اختر التصنيف');
      return;
    }
    setState(() => _starting = true);
    try {
      final body = await _api.startPieceScan({
        'safe_box_id': _locationId,
        'kind': _kind,
        if (_scopeKind == 'section') 'section_id': _sectionId,
        if (_scopeKind == 'category') 'category_id': _categoryId,
      });
      if (mounted) _enter(body['scan'] as Map<String, dynamic>);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _resume(int scanId) async {
    try {
      final body = await _api.pieceScan(scanId);
      if (mounted) _enter(body['scan'] as Map<String, dynamic>);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  /// The scan opened: the reader's presses go on from the server's count.
  void _enter(Map<String, dynamic> scan) {
    _capture?.dispose();
    final capture = ReaderCapture(
      onEvents: _took,
      elapsed: widget.elapsed,
      pressesBefore: (scan['presses'] as num?)?.toInt() ?? 0,
      clearAfterRead: true,
    )..start();
    setState(() {
      _scan = scan;
      _capture = capture;
      _waiting.clear();
      _sending = null;
    });
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(widget.sendEvery, (_) => _send());
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _took(List<ReaderEvent> events) {
    if (_scan?['status'] != 'open') return;
    _waiting.addAll([
      for (final e in events) {'kind': e.kind, if (e.value != null) 'value': e.value, 'press': e.press, 'ms': e.ms},
    ]);
  }

  static String _newKey() => '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';

  /// One batch at a time, each once by its key: a batch that met no answer is
  /// sent again under the same key, so the server keeps it once.
  Future<void> _send() async {
    final scan = _scan;
    if (scan == null || scan['status'] != 'open') return;
    if (_sending == null) {
      if (_waiting.isEmpty) return;
      _sending = (key: _newKey(), events: List.of(_waiting));
      _waiting.clear();
    }
    final batch = _sending!;
    try {
      final body = await _api.pieceScanReads(scan['id'] as int, batch.key, batch.events);
      if (!mounted) return;
      setState(() {
        _scan = body['scan'] as Map<String, dynamic>;
        _sending = null;
        _offline = false;
      });
    } on ApiException catch (e) {
      // refused (the scan closed elsewhere, a batch not understood): said, not sent again
      if (!mounted) return;
      setState(() => _sending = null);
      AppFeedback.error(context, e);
    } catch (_) {
      if (mounted && !_offline) setState(() => _offline = true);
    }
  }

  Future<void> _finish({bool early = false}) async {
    final scan = _scan;
    if (scan == null) return;
    String? reason;
    if (early) {
      reason = await _askReason();
      if (reason == null || reason.trim().isEmpty || !mounted) return;
    }
    setState(() => _finishing = true);
    await _send();
    try {
      final body = await _api.finishPieceScan(scan['id'] as int, early: early, reason: reason);
      if (!mounted) return;
      _sendTimer?.cancel();
      setState(() => _scan = body['scan'] as Map<String, dynamic>);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  Future<String?> _askReason() =>
      showDialog<String>(context: context, builder: (_) => const _EarlyReasonDialog());

  Future<void> _abandon() async {
    final scan = _scan;
    if (scan == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('ترك الجرد؟'),
          content: const Text('لا يُحكم على شيء، ويبقى في السجلّ «متروكًا».'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('رجوع')),
            FilledButton(
              key: const Key('scan-abandon-sure'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('اترك الجرد'),
            ),
          ],
        ),
      ),
    );
    if (sure != true || !mounted) return;
    try {
      final body = await _api.abandonPieceScan(scan['id'] as int);
      if (!mounted) return;
      _sendTimer?.cancel();
      setState(() => _scan = body['scan'] as Map<String, dynamic>);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  void _again() {
    _sendTimer?.cancel();
    _capture?.dispose();
    setState(() {
      _scan = null;
      _capture = null;
    });
    _loadStart();
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('جرد بالمسح'),
          actions: [
            if (scan != null && scan['status'] == 'open')
              PopupMenuButton<String>(
                key: const Key('scan-menu'),
                onSelected: (what) => what == 'early' ? _finish(early: true) : _abandon(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'early', key: Key('scan-early'), child: Text('إنهاء قبل اكتمال المسح')),
                  PopupMenuItem(value: 'abandon', key: Key('scan-abandon'), child: Text('ترك الجرد')),
                ],
              ),
          ],
        ),
        body: scan == null
            ? _startView(context)
            : scan['status'] == 'open'
                ? _scanView(context, scan)
                : _resultView(context, scan),
      ),
    );
  }

  // ── the start ──

  Widget _startView(BuildContext context) {
    final theme = Theme.of(context);
    final locations = _locations;
    if (_error != null && locations == null) {
      return AppErrorView(title: 'تعذّر تحميل الجرد', error: _error!, onRetry: _loadStart);
    }
    if (locations == null) return const AppLoadingView();
    if (locations.isEmpty) {
      return const AppEmptyView(title: 'لا موقع مخزون يُجرد', icon: Icons.inventory_2_outlined);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final o in _open)
        Card(
          key: Key('scan-open-${o['id']}'),
          child: ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text('جلسة مفتوحة: ${o['safe_name']} — ${o['kind_words']} — ${o['scope_words']}'),
            subtitle: Text('بدأها ${o['started_by'] ?? ''} · موجودة ${o['found']} من ${o['expected']}'),
            trailing: TextButton(onPressed: () => _resume(o['id'] as int), child: const Text('متابعة')),
          ),
        ),
      Text('الموقع', style: theme.textTheme.titleSmall),
      DropdownButtonFormField<int>(
        key: const Key('scan-location'),
        initialValue: _locationId,
        items: [for (final l in locations) DropdownMenuItem(value: l['id'] as int, child: Text('${l['name']}'))],
        onChanged: (v) => setState(() => _locationId = v),
      ),
      const SizedBox(height: 16),
      Text('النوع', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        key: const Key('scan-kind'),
        showSelectedIcon: false,
        segments: [for (final k in kinds.entries) ButtonSegment(value: k.key, label: Text(k.value))],
        selected: {_kind},
        onSelectionChanged: (v) => setState(() => _kind = v.first),
      ),
      const SizedBox(height: 16),
      Text('النطاق', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        key: const Key('scan-scope'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'all', label: Text('كل القطع')),
          ButtonSegment(value: 'section', label: Text('قسم')),
          ButtonSegment(value: 'category', label: Text('تصنيف')),
        ],
        selected: {_scopeKind},
        onSelectionChanged: (v) => setState(() => _scopeKind = v.first),
      ),
      if (_scopeKind == 'section')
        DropdownButtonFormField<int>(
          key: const Key('scan-section'),
          initialValue: _sectionId,
          hint: Text(_sections.isEmpty ? 'لا أقسام بعد: تُضبط من «إدارة التصنيفات»' : 'اختر القسم'),
          items: [for (final s in _sections) DropdownMenuItem(value: s['id'] as int, child: Text('${s['name']}'))],
          onChanged: (v) => setState(() => _sectionId = v),
        ),
      if (_scopeKind == 'category')
        DropdownButtonFormField<int>(
          key: const Key('scan-category'),
          initialValue: _categoryId,
          hint: const Text('اختر التصنيف'),
          items: [for (final c in _categories) DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}'))],
          onChanged: (v) => setState(() => _categoryId = v),
        ),
      const SizedBox(height: 24),
      FilledButton.icon(
        key: const Key('scan-start'),
        onPressed: _starting ? null : _start,
        icon: const Icon(Icons.sensors),
        label: const Text('ابدأ الجرد'),
      ),
    ]);
  }

  // ── the scan ──

  Widget _scanView(BuildContext context, Map<String, dynamic> scan) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final complete = (scan['completeness'] as Map?)?['complete'] == true;
    final needs = (scan['completeness'] as Map?)?['needs_presses'] ?? 3;
    final reads = (scan['reads'] as List? ?? []).cast<Map<String, dynamic>>();
    final alerts = reads.where((r) => r['verdict'] != 'found' && r['verdict'] != 'other_scope').toList();
    final found = reads.where((r) => r['verdict'] == 'found').toList();
    final others = reads.where((r) => r['verdict'] == 'other_scope').length;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('${scan['safe_name']} — ${scan['kind_words']} — ${scan['scope_words']}',
          key: const Key('scan-title'), style: theme.textTheme.titleSmall),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _figure(context, 'scan-found', 'موجودة', '${scan['found']} من ${scan['expected']}', tones.ready)),
        const SizedBox(width: 12),
        Expanded(child: _figure(context, 'scan-alerts', 'تنبيهات', '${scan['alerts']}',
            (scan['alerts'] as num? ?? 0) > 0 ? tones.warning : null)),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Icon(complete ? Icons.check_circle_outline : Icons.sensors, color: complete ? tones.ready.fg : theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            complete
                ? 'لا جديد في آخر $needs ضغطات — أنهِ إن مررت على كل أماكن العرض، أو تابع المسح'
                : 'جارٍ المسح… مرّ بالقارئ على كل أماكن العرض',
            key: const Key('scan-state'),
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ]),
      if (_offline)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('لا اتصال بالخادم: القراءات محفوظة على القارئ وتُرسل حين يعود',
              key: const Key('scan-offline'), style: TextStyle(color: tones.blocked.fg)),
        ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('scan-field'),
        controller: _capture!.field,
        focusNode: _focus,
        autofocus: true,
        maxLines: 2,
        textDirection: TextDirection.ltr,
        decoration: const InputDecoration(labelText: 'ما يكتبه القارئ (اضغط هنا ثم امسح)', isDense: true),
        onChanged: _capture!.typed,
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('scan-finish'),
        onPressed: complete && !_finishing ? () => _finish() : null,
        icon: const Icon(Icons.flag_outlined),
        label: const Text('إنهاء الجرد'),
      ),
      const SizedBox(height: 16),
      if (alerts.isNotEmpty) ...[
        Text('التنبيهات (${alerts.length})', style: theme.textTheme.titleSmall),
        for (final r in alerts) _readTile(context, r),
      ],
      if (others > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('من نطاق آخر: $others — لا تُحسب في هذا الجرد', key: const Key('scan-other-scope'),
              style: theme.textTheme.bodySmall),
        ),
      if (found.isNotEmpty)
        ExpansionTile(
          key: const Key('scan-found-list'),
          title: Text('الموجودة (${found.length})'),
          children: [for (final r in found) _readTile(context, r)],
        ),
    ]);
  }

  Widget _figure(BuildContext context, String key, String name, String value, SemanticTone? tone) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone?.container ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: theme.textTheme.bodySmall?.copyWith(color: tone?.onContainer)),
        Text(value, key: Key(key),
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: tone?.onContainer)),
      ]),
    );
  }

  Widget _readTile(BuildContext context, Map<String, dynamic> r) {
    final theme = Theme.of(context);
    // a print attempt whose end is not known, its tag read here: settled by
    // this very reading (ADR-085 ت2 §3) -- while the scan is open
    final settle = _scan?['status'] == 'open' && r['verdict'] == 'unconfirmed' && r['unsettled'] == true;
    return ListTile(
      key: Key('scan-read-${r['value']}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${r['verdict_words'] ?? r['verdict']}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
      subtitle: Text([
        '${r['words'] ?? r['value']}',
        if (r['moved'] != null) '${r['moved']}',
      ].join(' — ')),
      trailing: settle
          ? TextButton(
              key: Key('scan-settle-${r['value']}'),
              onPressed: () => _settle(r),
              child: const Text('اعتمد هذه البطاقة'),
            )
          : null,
    );
  }

  Future<void> _settle(Map<String, dynamic> read) async {
    final scan = _scan;
    if (scan == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اعتماد هذه البطاقة؟'),
          content: Text('قرأ القارئ رقاقتها الآن: تُعتمد محاولتها بجيلها، ويُكتب ذلك باسمك.\n${read['words'] ?? ''}'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('رجوع')),
            FilledButton(
              key: const Key('scan-settle-sure'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('اعتمدها'),
            ),
          ],
        ),
      ),
    );
    if (sure != true || !mounted) return;
    try {
      final body = await _api.settlePieceScanRead(scan['id'] as int, read['id'] as int);
      if (mounted) setState(() => _scan = body['scan'] as Map<String, dynamic>);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  // ── the result: one view with the computer's log ──

  Widget _resultView(BuildContext context, Map<String, dynamic> scan) => PieceScanResult(
        scan: scan,
        trailing: OutlinedButton.icon(
          key: const Key('scan-again'),
          onPressed: _again,
          icon: const Icon(Icons.restart_alt),
          label: const Text('جرد جديد'),
        ),
      );
}

/// «إنهاء قبل اكتمال المسح»: its reason asked, its field its own -- disposed
/// once the dialog is gone, not while it closes.
class _EarlyReasonDialog extends StatefulWidget {
  const _EarlyReasonDialog();

  @override
  State<_EarlyReasonDialog> createState() => _EarlyReasonDialogState();
}

class _EarlyReasonDialogState extends State<_EarlyReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          key: const Key('scan-early-dialog'),
          scrollable: true,
          title: const Text('إنهاء قبل اكتمال المسح'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('القطع التي لم تُقرأ تُقال «لم تُقرأ (مسح غير مكتمل)» لا «ناقصة»، ويقول السجلّ إن الجرد أُنهي مبكرًا.'),
            TextField(
              key: const Key('scan-early-reason'),
              controller: _reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'السبب'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('رجوع')),
            FilledButton(
              key: const Key('scan-early-sure'),
              onPressed: () => Navigator.of(context).pop(_reason.text),
              child: const Text('إنهاء'),
            ),
          ],
        ),
      );
}
