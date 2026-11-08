import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/category_model.dart';
import '../models/safe_box_model.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/inline_number_cell.dart' show readTypedNumber;

/// «محطة ترميز القطع» (ADR-087 R3.4): the pieces of a received line, one by
/// one -- each weighed (typed until the scale is linked, R5), numbered by the
/// server «KJ-», its wage read from its line or awaiting the invoice. The
/// pieces of a line weigh no more than it; the rest stays weight in its
/// category. A batch of the stock a location already holds is coded the same
/// way (R3.5): its wage entered by hand. The laws are the server's: this
/// screen sends and says.
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
    });
    _weightFocus.requestFocus();
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

  /// A receipt line's supplier, or a batch's location.
  static String _whence(Map<String, dynamic> l) =>
      '${(_isBatch(l) ? l['safe_name'] : l['supplier_name']) ?? '-'}';

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
              '${_whence(line)} — ${line['invoice_number'] ?? ''}\n${_counter(line)}',
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

/// A batch of a location's stock to code (R3.5): the location, the category
/// tracked by the piece, what it holds not yet coded (the server's), the
/// weight to code and its wage -- per gram, or the batch's whole divided by
/// its weight (the owner, 9 Nov 2026). Returns the request's body.
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
  bool _wageWhole = false;
  String? _problem;

  final _weight = TextEditingController();
  final _wage = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _weight.dispose();
    _wage.dispose();
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
      if (mounted) setState(() => _room = (room['room'] as num?)?.toDouble());
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    }
  }

  void _submit() {
    final weight = readTypedNumber(_weight.text) ?? 0;
    final wage = readTypedNumber(_wage.text);
    if (_safeId == null || _categoryId == null) {
      setState(() => _problem = 'اختر الموقع والتصنيف');
    } else if (weight <= 0) {
      setState(() => _problem = 'أدخل وزن الدفعة');
    } else if (wage == null || wage < 0) {
      setState(() => _problem = 'أدخل الأجرة: صفر أو أكثر');
    } else {
      Navigator.of(context).pop(<String, dynamic>{
        'safe_box_id': _safeId,
        'category_id': _categoryId,
        'weight': weight,
        'wage_per_gram': _wageWhole ? wage / weight : wage,
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
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('أجرة الجرام')),
                        ButtonSegment(
                          value: true,
                          label: Text('أجرة الدفعة كلها'),
                        ),
                      ],
                      selected: {_wageWhole},
                      onSelectionChanged: (v) =>
                          setState(() => _wageWhole = v.first),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('coding-wage'),
                      controller: _wage,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: _wageWhole
                            ? 'أجرة الدفعة كلها'
                            : 'أجرة الجرام',
                      ),
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
