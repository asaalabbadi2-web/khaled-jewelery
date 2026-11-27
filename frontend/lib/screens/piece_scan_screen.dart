import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/piece_scan_result.dart';
import '../widgets/reader_capture.dart';
import '../widgets/reader_receiver.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../utils/display_date.dart';
import '../utils/scan_feedback.dart';

/// «جرد بالمسح» on the handheld reader (ADR-085 ت2 ج1; the owner, 21 Nov 2026).
///
/// A location, its kind, its scope -- a section, a category, or every piece --
/// then the reader passed over every place the pieces are shown, its button
/// held or pressed. What the reader sends ([ReaderCapture]) goes to the server
/// in batches, each once by its key; every verdict and every figure is the
/// server's. A batch the server did not take for a passing reason -- no
/// answer, restarted, failed inside, the session ended -- is kept in this page
/// and sent again under its key (the key makes a second sending harmless), and
/// the screen says where its reads are: in this page alone, not on the reader;
/// only a refusal that would come again drops it. Nothing finishes by itself:
/// «إنهاء الجرد» waits for the server's «complete» -- no new tag in the last
/// presses -- and for every read sent; before it only an early finish with its
/// reason, said so in the scan's log.
///
/// A location holds more than 500 pieces (the owner, 27 Nov 2026): a batch's
/// answer carries every alert and only the reads after the last one this screen
/// holds ([_reads], merged by id); its figures -- found, alerts, other scope --
/// are the server's of every read.
class PieceScanScreen extends StatefulWidget {
  const PieceScanScreen({super.key, this.api, this.elapsed, this.sendEvery = const Duration(milliseconds: 400)});
  final ApiService? api;

  /// Milliseconds on the reader -- a stopwatch unless given (a test's).
  final int Function()? elapsed;

  /// How often what the reader sent goes to the server.
  final Duration sendEvery;

  /// The most reads a batch carries: the server takes 2000 at most (services/piece_scan.EVENTS_A_BATCH)
  /// and refuses a longer one for good -- what waited while it was out of reach goes in batches of
  /// this many, none refused.
  static const batchMost = 1000;

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
  /// Why the last batch is waiting to be sent again, or null: [_noServer] or [_sessionEnded].
  String? _unsent;
  bool _finishing = false;

  /// Every read the server has said, by its id -- an answer brings the reads after the last held.
  final Map<int, Map<String, dynamic>> _reads = {};
  int get _lastReadId => _reads.keys.fold(0, max);

  /// The scan's expected pieces, as the server said them when it was read whole (opened, read again):
  /// what is left to read is these, the found taken away (the owner, 27 Nov 2026: «ما بقي»).
  List<Map<String, dynamic>> _expected = const [];

  /// The alerts a tone has said, and whether «every piece found» has (the owner, 27 Nov 2026: the
  /// eyes on the vitrine, the reader's own beep off): each once; a found read says nothing.
  final Set<Object?> _heard = {};
  bool _allFoundHeard = false;

  static bool _isAlert(Map<String, dynamic> r) => r['verdict'] != 'found' && r['verdict'] != 'other_scope';

  /// What the server's answer to a batch says aloud: a tone for a read to look at not heard before,
  /// one when every piece expected is found -- the system's own word ([ScanFeedback]).
  void _sayAloud(Map<String, dynamic> scan) {
    final alerts = (scan['reads'] as List? ?? const []).whereType<Map<String, dynamic>>().where(_isAlert);
    if (alerts.map((r) => r['id']).where(_heard.add).toList().isNotEmpty) ScanFeedback.refused();
    final allFound = (scan['completeness'] as Map?)?['all_found'] == true;
    if (allFound && !_allFoundHeard) ScanFeedback.added();
    _allFoundHeard = allFound;
  }

  /// The scan as the server said it: its reads merged into [_reads] -- replaced when it said them all.
  void _hold(Map<String, dynamic> scan) {
    final expected = scan['expected_pieces'];
    if (scan['status'] == 'open' && expected is List) _expected = expected.cast<Map<String, dynamic>>();
    final said = (scan['reads'] as List? ?? const []).whereType<Map<String, dynamic>>();
    if (scan['reads_since'] == null) _reads.clear();
    for (final r in said) {
      if (r['id'] is int) _reads[r['id'] as int] = r;
    }
    _scan = scan;
  }

  static const _noServer =
      'لا يصل الخادم: قراءات لم تُرسل بعد، وهي في هذه الصفحة وحدها — لا تغلقها ولا تُعِد تحميلها حتى تُرسل';
  static const _sessionEnded =
      'انتهت الجلسة: سجّل الدخول من جديد في نافذة أخرى — القراءات في هذه الصفحة تُرسل بعده، فلا تغلقها';

  /// A batch not taken for a passing reason, sent again under its key: no answer (not an
  /// [ApiException]), the server restarted or failed inside (5xx), the session ended (401), too
  /// many or too slow (429, 408). Any other refusal would come again: the batch is dropped, said.
  static bool _passing(ApiException e) =>
      e.statusCode >= 500 || const {401, 408, 429}.contains(e.statusCode);

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
    _heard
      ..clear()
      ..addAll([for (final r in (scan['reads'] as List? ?? const []).whereType<Map<String, dynamic>>()) if (_isAlert(r)) r['id']]);
    _allFoundHeard = (scan['completeness'] as Map?)?['all_found'] == true;
    setState(() {
      _hold(scan);
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
      final take = min(_waiting.length, PieceScanScreen.batchMost);
      _sending = (key: _newKey(), events: List.of(_waiting.take(take)));
      _waiting.removeRange(0, take);
    }
    final batch = _sending!;
    try {
      final body = await _api.pieceScanReads(scan['id'] as int, batch.key, batch.events, since: _lastReadId);
      if (!mounted) return;
      // the panel says each value as the server judged it, not the tag's raw value
      for (final r in ((body['scan'] as Map?)?['reads'] as List? ?? const []).whereType<Map>()) {
        final words = r['words'] ?? r['verdict_words'];
        if (r['value'] != null && words != null) _capture?.describe('${r['value']}', '$words');
      }
      _sayAloud(body['scan'] as Map<String, dynamic>);
      setState(() {
        _hold(body['scan'] as Map<String, dynamic>);
        _sending = null;
        _unsent = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (_passing(e)) {
        final why = e.statusCode == 401 ? _sessionEnded : _noServer;
        if (_unsent != why) setState(() => _unsent = why);
        return;
      }
      // refused for good (the scan closed elsewhere, a batch not understood): said, not sent again
      setState(() {
        _sending = null;
        _unsent = null;
      });
      AppFeedback.error(context, e);
    } catch (_) {
      if (mounted && _unsent != _noServer) setState(() => _unsent = _noServer);
    }
  }

  /// Reads the reader sent that the server has not taken yet.
  bool get _readsUnsent => _sending != null || _waiting.isNotEmpty;

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
    if (!mounted) return;
    if (_readsUnsent) {
      // judged without them, a piece read only in them would be said missing
      setState(() => _finishing = false);
      AppFeedback.warning(context, 'قراءات لم تصل الخادم بعد: لا يُنهى الجرد حتى تُرسل');
      return;
    }
    try {
      final body = await _api.finishPieceScan(scan['id'] as int, early: early, reason: reason);
      if (!mounted) return;
      _sendTimer?.cancel();
      setState(() => _hold(body['scan'] as Map<String, dynamic>));
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
      setState(() => _hold(body['scan'] as Map<String, dynamic>));
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
      _reads.clear();
      _expected = const [];
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
            subtitle: Text(isolateLatin(
                'بدأها ${o['started_by_name'] ?? o['started_by'] ?? ''} · موجودة ${o['found']} من ${o['expected']}')),
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
      const SizedBox(height: 6),
      _lastScan(context, locations),
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

  /// The chosen place's last finished count, as the server says it with the places.
  Widget _lastScan(BuildContext context, List<Map<String, dynamic>> locations) {
    final theme = Theme.of(context);
    final place = locations.where((l) => l['id'] == _locationId).firstOrNull;
    final last = place?['last_scan'] as Map?;
    final missing = (last?['missing'] as num? ?? 0).toInt();
    return Text(
      last == null
          ? 'لم يُجرد هذا الموقع بالمسح بعد'
          : isolateLatin('آخر جرد: ${last['kind_words']} · ${displayDateTime(last['finished_at'])} · '
              '${last['finished_by_name'] ?? ''} — موجودة ${last['found']} من ${last['expected']}'
              '${missing > 0 ? ' · ناقصة $missing' : ''}'
              '${last['complete'] == false ? ' · أُنهي قبل اكتمال المسح' : ''}'),
      key: const Key('scan-last'),
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  // ── the scan ──

  /// «ضغطة واحدة», «ضغطتان», «3 ضغطات», «11 ضغطة».
  static String _presses(int n) => switch (n) {
        <= 1 => 'ضغطة واحدة',
        2 => 'ضغطتان',
        >= 3 && <= 10 => '$n ضغطات',
        _ => '$n ضغطة',
      };

  Widget _scanView(BuildContext context, Map<String, dynamic> scan) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final complete = (scan['completeness'] as Map?)?['complete'] == true;
    // every piece expected found: none left to wait for (the owner's rehearsal, 23 Nov 2026)
    final allFound = (scan['completeness'] as Map?)?['all_found'] == true;
    final needs = (scan['completeness'] as Map?)?['needs_presses'] ?? 3;
    final quiet = ((scan['completeness'] as Map?)?['quiet_presses'] as num? ?? 0).toInt();
    final expected = (scan['expected'] as num? ?? 0).toInt();
    final foundCount = (scan['found'] as num? ?? 0).toInt();
    // every alert in each answer; the found as merged from the answers; the counts the server's
    final alerts = (scan['reads'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where((r) => r['verdict'] != 'found' && r['verdict'] != 'other_scope')
        .toList();
    final alertIds = {for (final r in alerts) r['id']};
    final found = _reads.values.where((r) => r['verdict'] == 'found' && !alertIds.contains(r['id'])).toList();
    final counts = (scan['counts'] as Map?) ?? const {};
    final others = (counts['other_scope'] as num? ?? 0).toInt();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('${scan['safe_name']} — ${scan['kind_words']} — ${scan['scope_words']}',
          key: const Key('scan-title'), style: theme.textTheme.titleSmall),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: ScanFigure(figureKey: 'scan-found', name: 'موجودة',
            value: '${scan['found']} من ${scan['expected']}', tone: tones.ready)),
        if (scan['expected_grams'] != null) ...[
          const SizedBox(width: 12),
          // the grams found against the grams expected -- the scale's figure beside the count's
          // (the owner's rehearsal, 23 Nov 2026: «عرض لبيانات مثل الوزن الممسوح»)
          Expanded(child: ScanFigure(figureKey: 'scan-grams', name: 'الوزن الموجود',
              value: ltrIsolate('${formatGrams(scan['found_grams'] as num? ?? 0, decimals: 2)} / '
                  '${formatGrams(scan['expected_grams'] as num, decimals: 2)} جم'),
              tone: tones.ready)),
        ],
        const SizedBox(width: 12),
        Expanded(child: ScanFigure(figureKey: 'scan-alerts', name: 'تنبيهات', value: '${scan['alerts']}',
            tone: (scan['alerts'] as num? ?? 0) > 0 ? tones.warning : null)),
      ]),
      // the grams by karat while scanning, when there is more than one karat (the server's figures)
      if (((scan['by_karat'] as List?)?.length ?? 0) > 1) ...[
        const SizedBox(height: 8),
        ScanKaratGrams(scan: scan),
      ],
      if (expected > 0) ...[
        const SizedBox(height: 8),
        Semantics(
          label: 'موجودة $foundCount من $expected',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const Key('scan-progress'),
              value: foundCount / expected,
              minHeight: 8,
              color: tones.ready.fg,
              backgroundColor: tones.ready.container,
            ),
          ),
        ),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Icon(complete ? Icons.check_circle_outline : Icons.sensors, color: complete ? tones.ready.fg : theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            allFound
                ? 'وُجدت كل القطع المتوقعة — يمكنك إنهاء الجرد'
                : complete
                ? 'لا جديد في آخر $needs ضغطات — أنهِ إن مررت على كل أماكن العرض، أو تابع المسح'
                : 'جارٍ المسح… مرّ بالقارئ على كل أماكن العرض',
            key: const Key('scan-state'),
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ]),
      if (_unsent != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_unsent!, key: const Key('scan-offline'), style: TextStyle(color: tones.blocked.fg)),
        ),
      const SizedBox(height: 8),
      ReaderReceiver(capture: _capture!, focusNode: _focus, fieldKey: const Key('scan-field')),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('scan-finish'),
        onPressed: complete && !_finishing ? () => _finish() : null,
        icon: const Icon(Icons.flag_outlined),
        label: const Text('إنهاء الجرد'),
      ),
      if (!complete)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'يُتاح الإنهاء بعد ${_presses(needs as int)} بلا قراءة جديدة — بقي ${_presses(needs - quiet)}',
            key: const Key('scan-finish-hint'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 16),
      if (alerts.isNotEmpty) ...[
        Text('التنبيهات (${alerts.length})', style: theme.textTheme.titleSmall),
        for (final r in alerts) _readTile(context, r),
      ],
      if (others > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('من نطاق آخر: $others — خارج حساب هذا الجرد', key: const Key('scan-other-scope'),
              style: theme.textTheme.bodySmall),
        ),
      if (_expected.isNotEmpty) _leftList(context, found),
      if (found.isNotEmpty)
        ExpansionTile(
          key: const Key('scan-found-list'),
          title: Text('الموجودة (${(counts['found'] as num?)?.toInt() ?? found.length})'),
          children: [for (final r in found) _readTile(context, r)],
        ),
    ]);
  }

  /// «قطعة واحدة», «قطعتان», «5 قطع», «40 قطعة».
  static String _piecesWord(int n) => switch (n) {
        1 => 'قطعة واحدة',
        2 => 'قطعتان',
        >= 3 && <= 10 => '$n قطع',
        _ => '$n قطعة',
      };

  /// What is left to read: the expected pieces not found yet -- each one while they are few, by what
  /// they are when many (how many, and their grams, the most first): a vitrine of thousands is read by
  /// its kinds, not a list of numbers.
  Widget _leftList(BuildContext context, List<Map<String, dynamic>> found) {
    final foundIds = {for (final r in found) r['item_id']};
    final left = _expected.where((p) => !foundIds.contains(p['item_id'])).toList();
    final List<Widget> lines;
    if (left.length <= 30) {
      lines = [
        for (final p in left)
          ListTile(
            key: Key('scan-left-${p['item_id']}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(isolateLatin('${p['item_code']} · ${p['piece_name'] ?? ''} · '
                '${formatGrams((p['weight'] as num? ?? 0).toDouble(), decimals: 2)} جم')),
          ),
      ];
    } else {
      final kinds = <String, ({int n, double grams})>{};
      for (final p in left) {
        final name = '${p['piece_name'] ?? 'بلا اسم'}';
        final was = kinds[name] ?? (n: 0, grams: 0.0);
        kinds[name] = (n: was.n + 1, grams: was.grams + (p['weight'] as num? ?? 0).toDouble());
      }
      final order = kinds.entries.toList()..sort((a, b) => b.value.n.compareTo(a.value.n));
      lines = [
        for (final k in order)
          ListTile(
            key: Key('scan-left-kind-${k.key}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(isolateLatin(
                '${k.key}: ${_piecesWord(k.value.n)} · ${formatGrams(k.value.grams, decimals: 2)} جم')),
          ),
      ];
    }
    return ExpansionTile(
      key: const Key('scan-remaining'),
      title: Text('ما بقي (${left.length})'),
      children: lines,
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
      subtitle: Text(isolateLatin([
        '${r['words'] ?? r['value']}',
        // what it is and its weight, at a glance
        if (r['weight'] != null)
          '${r['piece_name'] ?? ''} ${formatGrams(r['weight'] as num, decimals: 2)} جم'.trim(),
        if (r['moved'] != null) '${r['moved']}',
      ].join(' — '))),
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
          content: Text(isolateLatin('قرأ القارئ رقاقتها الآن: تُعتمد محاولتها بجيلها، ويُكتب ذلك باسمك.\n${read['words'] ?? ''}')),
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
      if (mounted) setState(() => _hold(body['scan'] as Map<String, dynamic>));
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
