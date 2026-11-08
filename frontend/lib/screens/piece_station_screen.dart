import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/inline_number_cell.dart' show readTypedNumber;

/// «محطة ترميز القطع» (ADR-087 R3.4): the pieces of a received line, one by
/// one -- each weighed (typed until the scale is linked, R5), numbered by the
/// server «KJ-», its wage read from its line or awaiting the invoice. The
/// pieces of a line weigh no more than it; the rest stays weight in its
/// category. The laws are the server's: this screen sends and says.
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

  final _weight = TextEditingController();
  final _stones = TextEditingController();
  final _weightFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  @override
  void dispose() {
    _weight.dispose();
    _stones.dispose();
    _weightFocus.dispose();
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

  Future<void> _open(int lineId) async {
    try {
      final body = await _api.pieceLine(lineId);
      if (!mounted) return;
      setState(() {
        _line = body['line'] as Map<String, dynamic>;
        _pieces = (body['pieces'] as List? ?? []).cast<Map<String, dynamic>>();
        _last = null;
        _requestKey = null;
        _weight.clear();
        _stones.clear();
      });
      _weightFocus.requestFocus();
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
    // One attempt, one key: sent again after a lost answer, the same piece.
    // 0x7fffffff, not 1 << 32: on the web a shift is 32-bit.
    _requestKey ??=
        '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';
    setState(() => _saving = true);
    try {
      final saved = await _api.registerPiece({
        'line_id': line['line_id'],
        'weight': weight,
        'stones_weight': readTypedNumber(_stones.text) ?? 0,
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
      });
      _weightFocus.requestFocus();
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
        body: line == null ? _list(context) : _station(context, line),
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
      return const AppEmptyView(
        title: 'لا سطر ينتظر الترميز',
        hint: 'تظهر هنا أسطر الاستلام في التصنيفات المتتبَّعة بالقطعة',
        icon: Icons.task_alt,
      );
    }
    return RefreshIndicator(
      onRefresh: _loadPending,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final l in pending)
            Card(
              child: ListTile(
                key: Key('station-line-${l['line_id']}'),
                leading: const Icon(Icons.qr_code_2),
                title: Text(
                  '${l['category_name'] ?? '-'} — ${l['supplier_name'] ?? '-'}',
                ),
                subtitle: Text('${l['invoice_number'] ?? ''}\n${_counter(l)}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_left),
                onTap: () => _open(l['line_id'] as int),
              ),
            ),
        ],
      ),
    );
  }

  String _counter(Map<String, dynamic> l) =>
      'الوزن ${_g(l['weight'])} جم · رُمّز ${l['pieces']} قطعة · الباقي ${_g(l['rest'])} جم';

  static String _g(Object? v) =>
      formatGrams((v as num? ?? 0).toDouble(), decimals: 2);

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
              '${line['supplier_name'] ?? '-'} — ${line['invoice_number'] ?? ''}\n${_counter(line)}',
              key: const Key('station-counter'),
            ),
            isThreeLine: true,
          ),
        ),
        const SizedBox(height: 12),
        if (rest > 0.0005) ...[
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
                '${_g(last['weight'])} جم — اكتب الرقم على بطاقة القطعة',
              ),
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
              '${((p['stones_weight'] as num?) ?? 0) > 0 ? ' · فصوص ${_g(p['stones_weight'])} جم' : ''}',
            ),
            trailing: Text(
              p['wage_known'] == true
                  ? 'الأجرة ${formatAmount((p['wage'] as num).toDouble())}'
                  : 'بانتظار الفاتورة',
            ),
          ),
      ],
    );
  }
}
