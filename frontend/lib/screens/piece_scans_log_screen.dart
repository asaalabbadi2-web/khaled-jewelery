import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_breakpoints.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/display_date.dart';
import '../widgets/app_state_views.dart';
import '../widgets/piece_scan_result.dart';
import '../utils/bidi.dart';

/// «سجلّ الجرد بالمسح» on the computer (ADR-085 ت2 ج3), in «الجرد الفعلي»:
/// every count by scan, the newest first -- its place, kind, scope, who and
/// when, how it ended, and its counts by verdict, all the server's; a scan
/// opened shows its result as frozen at its finish. For reading: nothing here
/// changes a count, a piece or the books.
class PieceScansLogScreen extends StatefulWidget {
  const PieceScansLogScreen({super.key, this.api});
  final ApiService? api;

  @override
  State<PieceScansLogScreen> createState() => _PieceScansLogScreenState();
}

class _PieceScansLogScreenState extends State<PieceScansLogScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>>? _scans;
  Object? _error;

  /// The log by its location and its period, asked of the server; those that
  /// found pieces missing alone if asked (the owner, 22 Nov 2026).
  List<Map<String, dynamic>> _locations = const [];
  int? _safeBoxId;
  String? _period;
  bool _onlyMissing = false;

  static const periods = {null: 'الكل', 'today': 'اليوم', 'week': 'آخر 7 أيام', 'month': 'هذا الشهر'};

  @override
  void initState() {
    super.initState();
    _load();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final body = await _api.pieceScanLocations();
      if (mounted) setState(() => _locations = (body['locations'] as List? ?? []).cast<Map<String, dynamic>>());
    } catch (_) {
      // no locations read: the log by period alone
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final body = await _api.pieceScans(safeBoxId: _safeBoxId, period: _period);
      if (mounted) setState(() => _scans = (body['scans'] as List? ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// How it ended, in a word.
  static String stateOf(Map<String, dynamic> s) => switch (s['status']) {
        'open' => 'مفتوحة',
        'abandoned' => 'متروكة',
        _ => s['complete'] == true ? 'مكتمل' : 'أُنهي مبكرًا',
      };

  static int _n(Map<String, dynamic> s, String verdict) =>
      ((s['expected_counts'] as Map?)?[verdict] as num? ?? 0).toInt();

  void _open(Map<String, dynamic> s) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => _PieceScanDetail(api: _api, scanId: s['id'] as int),
      ));

  Widget _filters(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (_locations.isNotEmpty)
          DropdownButton<int?>(
            key: const Key('scans-location'),
            value: _safeBoxId,
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('كل المواقع')),
              for (final l in _locations) DropdownMenuItem<int?>(value: l['id'] as int, child: Text('${l['name']}')),
            ],
            onChanged: (v) {
              setState(() => _safeBoxId = v);
              _load();
            },
          ),
        for (final e in periods.entries)
          ChoiceChip(
            key: Key('scans-period-${e.key ?? 'all'}'),
            label: Text(e.value),
            selected: _period == e.key,
            onSelected: (_) {
              setState(() => _period = e.key);
              _load();
            },
          ),
        FilterChip(
          key: const Key('scans-only-missing'),
          avatar: Icon(Icons.report_outlined, size: 18, color: AppSemanticColors.of(context).warning.fg),
          label: Text('فيها ناقصة', style: theme.textTheme.bodyMedium),
          selected: _onlyMissing,
          onSelected: (v) => setState(() => _onlyMissing = v),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _scans;
    final scans = all == null || !_onlyMissing ? all : all.where((s) => _n(s, 'missing') > 0).toList();
    final filtered = _safeBoxId != null || _period != null || _onlyMissing;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سجلّ الجرد بالمسح'),
          actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'تحديث', onPressed: _load)],
        ),
        body: Column(children: [
          if (all != null && (all.isNotEmpty || filtered)) _filters(context),
          Expanded(
            child: _error != null && scans == null
                ? AppErrorView(title: 'تعذّر تحميل سجلّ الجرد', error: _error!, onRetry: _load)
                : scans == null
                    ? const AppLoadingView()
                    : scans.isEmpty
                        ? filtered
                            ? const AppEmptyView(
                                title: 'لا جرد في هذا الاختيار',
                                hint: 'غيّر الموقع أو الفترة، أو اختر «الكل».',
                                icon: Icons.filter_alt_off_outlined,
                              )
                            : const AppEmptyView(
                                title: 'لا جرد بالمسح بعد',
                                hint: 'يُجرد بالقارئ المحمول من «جرد بالمسح»، وكل جلسة تُحفظ هنا بنتيجتها.',
                                icon: Icons.sensors,
                              )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: AppBreakpoints.listsAsCards(context) ? _cards(context, scans) : _table(context, scans),
                          ),
          ),
        ]),
      ),
    );
  }

  Widget _state(BuildContext context, Map<String, dynamic> s) {
    final tones = AppSemanticColors.of(context);
    final word = stateOf(s);
    final tone = word == 'مكتمل' ? tones.ready : (word == 'مفتوحة' ? tones.info : tones.warning);
    return Text(word, key: Key('scans-state-${s['id']}'), style: TextStyle(color: tone.fg, fontWeight: FontWeight.w700));
  }

  /// Its missing, marked by an icon and the warning's colour when there are any.
  Widget _missing(BuildContext context, Map<String, dynamic> s, {bool words = false}) {
    final n = _n(s, 'missing');
    final tones = AppSemanticColors.of(context);
    return Row(key: Key('scans-missing-${s['id']}'), mainAxisSize: MainAxisSize.min, children: [
      if (n > 0) ...[Icon(Icons.report_outlined, size: 18, color: tones.warning.fg), const SizedBox(width: 4)],
      Text(words ? 'ناقصة $n' : '$n',
          style: n > 0 ? TextStyle(color: tones.warning.fg, fontWeight: FontWeight.w800) : null),
    ]);
  }

  Widget _table(BuildContext context, List<Map<String, dynamic>> scans) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          key: const Key('scans-table'),
          showCheckboxColumn: false,
          columns: const [
            DataColumn(label: Text('بدأ')),
            DataColumn(label: Text('الموقع')),
            DataColumn(label: Text('النوع')),
            DataColumn(label: Text('النطاق')),
            DataColumn(label: Text('من')),
            DataColumn(label: Text('الحال')),
            DataColumn(label: Text('موجودة'), numeric: true),
            DataColumn(label: Text('ناقصة'), numeric: true),
            DataColumn(label: Text('بلا رقاقة'), numeric: true),
            DataColumn(label: Text('تحرّكت'), numeric: true),
            DataColumn(label: Text('تنبيهات'), numeric: true),
          ],
          rows: [
            for (final s in scans)
              DataRow(
                key: ValueKey('scans-row-${s['id']}'),
                onSelectChanged: (_) => _open(s),
                cells: [
                  DataCell(Text(displayDateTime(s['started_at']))),
                  DataCell(Text('${s['safe_name']}')),
                  DataCell(Text('${s['kind_words']}')),
                  DataCell(Text('${s['scope_words']}')),
                  DataCell(Text('${s['started_by_name'] ?? s['started_by'] ?? '—'}')),
                  DataCell(_state(context, s)),
                  DataCell(Text(isolateLatin('${s['found']} من ${s['expected']}'))),
                  DataCell(_missing(context, s)),
                  DataCell(Text('${_n(s, 'untagged')}')),
                  DataCell(Text('${_n(s, 'moved')}')),
                  DataCell(Text('${s['alerts']}')),
                ],
              ),
          ],
        ),
      ),
    ]);
  }

  Widget _cards(BuildContext context, List<Map<String, dynamic>> scans) {
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final s in scans)
        Card(
          key: ValueKey('scans-card-${s['id']}'),
          child: ListTile(
            onTap: () => _open(s),
            title: Text('${s['safe_name']} — ${s['kind_words']} — ${s['scope_words']}'),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                isolateLatin('${displayDateTime(s['started_at'])} · ${s['started_by_name'] ?? s['started_by'] ?? '—'}\n'
                    'موجودة ${s['found']} من ${s['expected']} · تنبيهات ${s['alerts']}'),
                style: theme.textTheme.bodySmall,
              ),
              _missing(context, s, words: true),
            ]),
            isThreeLine: true,
            trailing: _state(context, s),
          ),
        ),
    ]);
  }
}

/// One scan from the log: its result as the server froze it.
class _PieceScanDetail extends StatefulWidget {
  const _PieceScanDetail({required this.api, required this.scanId});
  final ApiService api;
  final int scanId;

  @override
  State<_PieceScanDetail> createState() => _PieceScanDetailState();
}

class _PieceScanDetailState extends State<_PieceScanDetail> {
  Map<String, dynamic>? _scan;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final body = await widget.api.pieceScan(widget.scanId);
      if (mounted) setState(() => _scan = body['scan'] as Map<String, dynamic>);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('جرد بالمسح')),
          body: _error != null && _scan == null
              ? AppErrorView(title: 'تعذّر تحميل الجرد', error: _error!, onRetry: _load)
              : _scan == null
                  ? const AppLoadingView()
                  : PieceScanResult(scan: _scan!),
        ),
      );
}
