import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../providers/auth_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/display_date.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/piece_label_actions.dart';
import 'items_screen_enhanced.dart' show showCategoriesManagement;
import 'piece_models_screen.dart';
import 'size_systems_screen.dart';

/// The piece states the server says (services/pieces.PIECE_STATES), in the
/// screen's words -- it adds none of its own.
const pieceStateLabels = <String, String>{
  'in_stock': 'في المخزون',
  'sold': 'بيعت',
  'returned_to_supplier': 'رُدّت إلى المورد',
  'out': 'خرجت من المخزون',
};

/// The karats the books hold (18, 21, 22, 24): a piece of another is not one.
const _karats = [18, 21, 22, 24];

/// Below this width the list is cards; above it, a table.
const double piecesTableFrom = 900;

/// «القطع» (the owner, 16 Nov 2026; ADR-087): each piece by its number, from
/// its receiving to its sale -- its place and state the books', searched,
/// filtered, sorted and paged by the server. A piece's weight, karat,
/// category, stones and wage are its receiving's facts; only its name and
/// description are edited.
class PiecesScreen extends StatefulWidget {
  const PiecesScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<PiecesScreen> createState() => _PiecesScreenState();
}

class _PiecesScreenState extends State<PiecesScreen> {
  final _search = TextEditingController();
  Timer? _searchPause;

  String _state = 'in_stock';
  int? _categoryId;
  int? _karat;
  int? _safeBoxId;
  // a model's or a size's id, or «none» for the pieces without (ADR-093 §4)
  String? _model;
  String? _size;
  // The labels waiting (ADR-097 ط4): the pieces with no adopted tag, chosen
  // and printed through the station's one engine -- «اطبع المحدد».
  bool _untagged = false;
  final Set<int> _selected = {};
  final Set<int> _busy = {};
  String? _batch;
  late final PieceLabelActions _labels = PieceLabelActions(
    api: widget.api,
    onLabel: _setLabel,
    onBusy: (id, busy) {
      if (mounted) setState(() => busy ? _busy.add(id) : _busy.remove(id));
    },
  );
  String _sort = 'number';
  bool _ascending = false;
  int _page = 1;
  static const _perPage = 25;

  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = false;
  ApiCancelToken? _request;

  List<Map<String, dynamic>> _categories = const [];
  List<SafeBoxModel> _places = const [];
  List<Map<String, dynamic>> _models = const [];
  List<Map<String, dynamic>> _systems = const [];

  final _grams = NumberFormat('#,##0.00', 'en');
  final _money = NumberFormat('#,##0.##', 'en');
  final _count = NumberFormat('#,##0', 'en');

  @override
  void initState() {
    super.initState();
    _load();
    _loadChoices();
  }

  @override
  void dispose() {
    _searchPause?.cancel();
    _request?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadChoices() async {
    try {
      final categories = await widget.api.getCategories();
      final safes = await widget.api.getSafeBoxes(safeType: 'gold', isActive: true);
      if (!mounted) return;
      setState(() {
        _categories = categories
            .whereType<Map>()
            .map((c) => Map<String, dynamic>.from(c))
            .where((c) => c['tracking'] == 'piece')
            .toList();
        _places = safes.where((s) => (s.stockLocation ?? '').isNotEmpty).toList();
      });
    } catch (_) {
      // The filters stay at «الكل»; the list itself says if it cannot load.
    }
    try {
      final models = await widget.api.getPieceModels(includeInactive: true);
      final systems = await widget.api.getSizeSystems();
      if (!mounted) return;
      setState(() {
        _models = models;
        _systems = systems;
      });
    } catch (_) {
      // without them, no model or size filter is offered
    }
  }

  Map<String, dynamic>? _categoryOf(int? id) =>
      id == null ? null : _categories.where((c) => c['id'] == id).firstOrNull;

  /// The sizes of a category's size system.
  List<Map<String, dynamic>> _sizesOf(int? categoryId) {
    final systemId = _categoryOf(categoryId)?['size_system_id'];
    final system = systemId == null ? null : _systems.where((s) => s['id'] == systemId).firstOrNull;
    return [for (final s in (system?['sizes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
  }

  String _modelOf(Map<String, dynamic> p) => (p['model'] as Map?)?['name']?.toString() ?? '—';

  String _sizeOf(Map<String, dynamic> p) => (p['size'] as Map?)?['label']?.toString() ?? '—';

  /// Reads the page asked: a new reading ends the last at once.
  Future<void> _load() async {
    _request?.cancel();
    final request = ApiCancelToken();
    _request = request;
    setState(() => _loading = true);
    try {
      final data = await widget.api.getPieces(
        q: _search.text,
        categoryId: _categoryId,
        karat: _karat,
        safeBoxId: _safeBoxId,
        modelId: _model,
        sizeId: _size,
        state: _state,
        untagged: _untagged,
        sort: _sort,
        ascending: _ascending,
        page: _page,
        perPage: _perPage,
        cancel: request,
      );
      if (mounted && identical(request, _request)) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (error) {
      if (request.isCancelled || !mounted) return;
      if (_data == null) {
        setState(() => _error = error);
      } else {
        AppFeedback.error(context, error, title: 'تعذّر تحديث القطع');
      }
    } finally {
      if (identical(request, _request)) {
        _request = null;
        request.cancel();
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  void _filter(void Function() change) {
    setState(() {
      change();
      _page = 1;
      _selected.clear();
    });
    _load();
  }

  void _setLabel(int pieceId, Map<String, dynamic> label) {
    final rows = (_data?['pieces'] as List?) ?? const [];
    setState(() {
      for (final row in rows) {
        if (row is Map && row['id'] == pieceId) {
          row['label'] = label;
          if (label['status'] == 'completed') row['tag'] = 'printed';
        }
      }
    });
  }

  void _onSearch(String _) {
    _searchPause?.cancel();
    _searchPause = Timer(const Duration(milliseconds: 350), () => _filter(() {}));
  }

  void _sortBy(String key) {
    _filter(() {
      if (_sort == key) {
        _ascending = !_ascending;
      } else {
        _sort = key;
        _ascending = key == 'name';
      }
    });
  }

  List<Map<String, dynamic>> get _pieces =>
      ((_data?['pieces'] as List?) ?? const []).whereType<Map>().map((p) => Map<String, dynamic>.from(p)).toList();

  // ── words and figures ────────────────────────────────────────────────────

  String _weight(Object? v) => _grams.format((v as num?) ?? 0);

  String? _wage(Map<String, dynamic> p) {
    final wage = p['wage'];
    return wage is num ? _money.format(wage) : null;
  }

  String? _perGram(Map<String, dynamic> p) {
    final wage = p['wage'];
    final weight = (p['weight'] as num?)?.toDouble() ?? 0;
    return wage is num && weight > 0 ? _grams.format(wage / weight) : null;
  }

  String _date(Object? iso) => displayDate(iso);

  String _receivedFrom(Map<String, dynamic> p) {
    final received = p['received'] as Map?;
    if (received == null) return '—';
    if (received['kind'] == 'coding') return 'ترميز من «${received['safe_name'] ?? 'المخزون'}»';
    return '${received['supplier_name'] ?? 'مورد'}';
  }

  Widget _ltr(String text, {TextStyle? style}) => Text(text, textDirection: TextDirection.ltr, style: style);

  Widget _stateChip(String state) {
    final tones = AppSemanticColors.of(context);
    final tone = state == 'in_stock' ? tones.ready : (state == 'out' ? tones.warning : tones.info);
    final scheme = Theme.of(context).colorScheme;
    final inStock = state == 'in_stock';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm + 2, vertical: 2),
      decoration: BoxDecoration(
        color: inStock ? tone.container : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        pieceStateLabels[state] ?? state,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: inStock ? tone.fg : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _karatChip(Object? karat) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 1),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: _ltr(
        '${karat ?? ''}',
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimaryContainer),
      ),
    );
  }

  // ── actions ──────────────────────────────────────────────────────────────

  /// One piece's label through the engine (ADR-097): printed, run, tried
  /// again -- a printed one reprinted with its reason, an unknown one settled.
  void _print(Map<String, dynamic> p) {
    final label = p['label'] as Map<String, dynamic>?;
    switch (label?['status'] as String?) {
      case 'completed':
        _labels.reprint(context, p);
      case 'needs_attention':
        _labels.resolve(context, p['id'] as int, '${p['item_code']}', label!['attempt_id'] as int);
      case 'pending':
      case 'printing':
      case 'verifying':
      case 'failed':
        _labels.retry(context, p['id'] as int, label!['job_id'] as int);
      default:
        // a tag adopted before ADR-097 (generation 0): printed -- reprinted with a reason
        p['tag'] != null ? _labels.reprint(context, p) : _labels.print(context, p);
    }
  }

  /// «اطبع المحدد»: one after another through the same engine; stopped at
  /// the first stop of the printer itself -- its labels, its ribbon, its
  /// cover -- that would fail the rest too; printed ones and unknown ones left.
  Future<void> _printSelected() async {
    final chosen = [for (final p in _pieces) if (_selected.contains(p['id'])) p];
    var printed = 0, skipped = 0;
    String? stopped;
    for (var i = 0; i < chosen.length; i++) {
      if (!mounted) return;
      setState(() => _batch = 'تُطبع ${i + 1} من ${chosen.length}…');
      final label = await _labels.advance(context, chosen[i]);
      if (label == null) {
        skipped++;
        continue;
      }
      if (label['status'] == 'completed') printed++;
      if (label['status'] == 'failed' && PieceLabelActions.printerStops.contains(label['error_code'])) {
        stopped = '${label['message'] ?? 'توقّفت الطابعة'}';
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _batch = null;
      _selected.clear();
    });
    final done = 'طُبعت $printed من ${chosen.length}${skipped > 0 ? ' · تُركت $skipped (مطبوعة أو تحتاج حسمًا)' : ''}';
    if (stopped != null) {
      AppFeedback.warning(context, 'توقّفت الطباعة: $stopped. $done');
    } else {
      AppFeedback.success(context, done);
    }
    _load();
  }

  /// The labels' line above the list: «بلا بطاقة», all chosen, and «اطبع المحدد».
  Widget _labelsBar() {
    final ids = [for (final p in _pieces) p['id'] as int];
    final all = ids.isNotEmpty && ids.every(_selected.contains);
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilterChip(
          key: const Key('pieces-untagged'),
          label: const Text('بلا بطاقة'),
          selected: _untagged,
          onSelected: (on) => _filter(() => _untagged = on),
        ),
        if (ids.isNotEmpty)
          TextButton.icon(
            key: const Key('pieces-select-all'),
            onPressed: _batch != null
                ? null
                : () => setState(() => all ? _selected.removeAll(ids) : _selected.addAll(ids)),
            icon: Icon(all ? Icons.check_box : Icons.check_box_outline_blank),
            label: Text(all ? 'إلغاء التحديد' : 'تحديد الصفحة'),
          ),
        if (_selected.isNotEmpty)
          FilledButton.icon(
            key: const Key('pieces-print-selected'),
            onPressed: _batch != null ? null : _printSelected,
            icon: const Icon(Icons.print),
            label: Text('اطبع المحدد (${_selected.length})'),
          ),
        if (_batch != null) Text(_batch!, key: const Key('pieces-print-progress')),
      ],
    );
  }

  Widget _choose(Map<String, dynamic> p) => Checkbox(
    key: Key('piece-select-${p['item_code']}'),
    value: _selected.contains(p['id']),
    onChanged: _batch != null
        ? null
        : (on) => setState(() => on == true ? _selected.add(p['id'] as int) : _selected.remove(p['id'])),
  );

  /// A piece's words (ADR-093 §5): its name, description, model and size --
  /// descriptions, recorded by the server; its book facts stay.
  Future<void> _editText(Map<String, dynamic> p) async {
    final name = TextEditingController(text: '${p['name'] ?? ''}');
    final description = TextEditingController(text: '${p['description'] ?? ''}');
    final models = [
      for (final m in _models)
        if ((m['category'] as Map?)?['id'] == p['category_id'] && (m['is_active'] != false || m['id'] == (p['model'] as Map?)?['id'])) m,
    ];
    int? modelId = (p['model'] as Map?)?['id'] as int?;
    int? sizeId = (p['size'] as Map?)?['id'] as int?;
    List<Map<String, dynamic>> offered() {
      final model = models.where((m) => m['id'] == modelId).firstOrNull;
      final named = [for (final s in (model?['sizes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
      return named.isNotEmpty ? named : _sizesOf(p['category_id'] as int?);
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('تعديل ${p['item_code']}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('piece-edit-name'),
                  controller: name,
                  decoration: const InputDecoration(labelText: 'الاسم'),
                ),
                const SizedBox(height: AppSpace.md),
                TextField(
                  key: const Key('piece-edit-description'),
                  controller: description,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'الوصف'),
                ),
                const SizedBox(height: AppSpace.md),
                DropdownButtonFormField<int?>(
                  key: const Key('piece-edit-model'),
                  initialValue: modelId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'الموديل'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('بلا موديل')),
                    for (final m in models)
                      DropdownMenuItem<int?>(value: m['id'] as int, child: Text('${m['name']}')),
                  ],
                  onChanged: (v) => setDialog(() {
                    modelId = v;
                    if (!offered().any((s) => s['id'] == sizeId)) sizeId = null;
                  }),
                ),
                if (offered().isNotEmpty) ...[
                  const SizedBox(height: AppSpace.md),
                  DropdownButtonFormField<int?>(
                    key: ValueKey('piece-edit-size-$modelId'),
                    initialValue: sizeId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'المقاس'),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('بلا مقاس')),
                      for (final s in offered())
                        DropdownMenuItem<int?>(value: s['id'] as int, child: Text('${s['label']}')),
                    ],
                    onChanged: (v) => setDialog(() => sizeId = v),
                  ),
                ],
                const SizedBox(height: AppSpace.md),
                Text(
                  'الوزن والعيار والتصنيف والأحجار والمصنعية حقائق استلامها، فلا تُعدَّل. '
                  'الاسم والوصف والموديل والمقاس أوصاف، ويُسجَّل كل تعديل لها.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(
              key: const Key('piece-edit-save'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    if (name.text.trim().isEmpty) {
      AppFeedback.warning(context, 'اسم القطعة لا يكون فارغًا');
      return;
    }
    try {
      await widget.api.updatePiece(p['id'] as int, {
        'name': name.text.trim(),
        'description': description.text.trim(),
        'model_id': modelId,
        'size_id': sizeId,
      });
      if (!mounted) return;
      AppFeedback.success(context, 'حُفظ تعديل القطعة ${p['item_code']}');
      _load();
    } catch (error) {
      if (mounted) AppFeedback.error(context, error, title: 'لم يُحفظ التعديل');
    }
  }

  bool get _canEdit => context.read<AuthProvider>().hasPermission('items.edit');

  Widget _actions(Map<String, dynamic> p) => PopupMenuButton<String>(
    key: Key('piece-actions-${p['item_code']}'),
    tooltip: 'إجراءات القطعة ${p['item_code']}',
    icon: const Icon(Icons.more_horiz),
    onSelected: (choice) => choice == 'print' ? _print(p) : _editText(p),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'print', child: Text('طباعة البطاقة')),
      if (_canEdit) const PopupMenuItem(value: 'edit', child: Text('تعديل الوصف والموديل والمقاس')),
    ],
  );

  /// A piece's card: its facts, and what may be done with it.
  void _open(Map<String, dynamic> p, {required bool wide}) {
    final body = _PieceCard(
      piece: p,
      state: _stateChip('${p['state']}'),
      karat: _karatChip(p['karat']),
      weight: _weight(p['weight']),
      facts: [
        ('الموديل', p['model'] == null ? 'بلا موديل' : _modelOf(p)),
        ('المقاس', p['size'] == null ? 'بلا مقاس' : _sizeOf(p)),
        ('الأحجار', (p['stones_weight'] as num? ?? 0) > 0 ? '${_weight(p['stones_weight'])} جم' : 'بلا أحجار'),
        ('المصنعية', _wage(p) == null ? 'بانتظار الفاتورة' : '${_wage(p)} ر.س · ${_perGram(p)} للجرام'),
        (
          'المكان',
          (p['location'] as Map?)?['name']?.toString() ??
              '${pieceStateLabels[p['state']] ?? ''} ${_date(p['left_at'])}',
        ),
        ('الرقاقة', p['tag'] != null ? 'مربوطة' : 'بلا رقاقة'),
        ('الاستلام', '${_date((p['received'] as Map?)?['date'])} · ${_receivedFrom(p)}'),
        if ((p['received'] as Map?)?['document'] != null) ('مستند الاستلام', '${(p['received'] as Map)['document']}'),
      ],
      onPrint: () {
        Navigator.pop(context);
        _print(p);
      },
      onEdit: _canEdit
          ? () {
              Navigator.pop(context);
              _editText(p);
            }
          : null,
    );
    if (wide) {
      showDialog<void>(
        context: context,
        builder: (_) => Dialog(child: SizedBox(width: 460, child: body)),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => body,
      );
    }
  }

  // ── the page ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('القطع'),
        actions: [
          IconButton(
            key: const Key('pieces-models'),
            tooltip: 'الموديلات',
            icon: const Icon(Icons.style_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => PieceModelsScreen(api: widget.api)))
                .then((_) => _loadChoices()),
          ),
          IconButton(
            key: const Key('pieces-size-systems'),
            tooltip: 'أنظمة المقاسات',
            icon: const Icon(Icons.straighten),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => SizeSystemsScreen(api: widget.api)))
                .then((_) => _loadChoices()),
          ),
          IconButton(
            key: const Key('pieces-categories'),
            tooltip: 'إدارة التصنيفات',
            icon: const Icon(Icons.category_outlined),
            onPressed: () => showCategoriesManagement(context, widget.api, onChanged: _loadChoices),
          ),
        ],
      ),
      body: _data == null && _error != null
          ? AppErrorView(title: 'تعذّر تحميل القطع', error: _error!, onRetry: _load)
          : _data == null
          ? const AppLoadingView()
          : LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= piecesTableFrom;
                return RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    children: [
                      if (_loading) const LinearProgressIndicator(minHeight: 2),
                      _summary(),
                      const SizedBox(height: AppSpace.md),
                      _filters(wide, box.maxWidth - 2 * AppSpace.lg),
                      const SizedBox(height: AppSpace.sm),
                      _labelsBar(),
                      const SizedBox(height: AppSpace.md),
                      if (_pieces.isEmpty) _empty() else if (wide) _table() else ..._pieces.map(_cardRow),
                      if (_pieces.isNotEmpty) _pager(),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _summary() {
    final summary = Map<String, dynamic>.from((_data?['summary'] as Map?) ?? const {});
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    Widget block(String key, String label, String value, {String? unit, String? more, bool warn = false}) => Container(
      key: Key('pieces-summary-$key'),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
      decoration: BoxDecoration(
        color: warn ? tones.warning.container : theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: AppSpace.sm,
        children: [
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: warn ? tones.warning.fg : null)),
          _ltr(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: warn ? tones.warning.fg : null,
            ),
          ),
          if (unit != null) Text(unit, style: theme.textTheme.bodyMedium),
          if (more != null) _ltr(more, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (more != null) Text('جم', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.sm,
      children: [
        block(
          'in-stock',
          'في المخزون',
          _count.format((summary['in_stock_count'] as num?) ?? 0),
          unit: 'قطعة ·',
          more: _weight(summary['in_stock_weight']),
        ),
        block('sold', 'بيعت هذا الشهر', _count.format((summary['sold_this_month'] as num?) ?? 0)),
        block(
          'untagged',
          'بلا رقاقة',
          _count.format((summary['in_stock_untagged'] as num?) ?? 0),
          warn: ((summary['in_stock_untagged'] as num?) ?? 0) > 0,
        ),
      ],
    );
  }

  Widget _filters(bool wide, double room) {
    InputDecoration box(String label) => InputDecoration(labelText: label, isDense: true);
    // A computer: each its width; a phone: the search across, the rest two a line.
    Widget sized(double width, Widget child, {bool half = true}) =>
        SizedBox(width: wide ? width : (half ? (room - AppSpace.md) / 2 : room), child: child);
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.sm,
      children: [
        sized(
          360,
          half: false,
          TextField(
            key: const Key('pieces-search'),
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: box(
              'بحث',
            ).copyWith(hintText: 'رقم القطعة أو اسمها، أو امسح رقاقتها', prefixIcon: const Icon(Icons.search)),
          ),
        ),
        sized(
          190,
          DropdownButtonFormField<int?>(
            key: const Key('pieces-category'),
            initialValue: _categoryId,
            isExpanded: true,
            decoration: box('التصنيف'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('الكل')),
              for (final c in _categories)
                DropdownMenuItem<int?>(
                  value: c['id'] as int?,
                  child: Text('${c['name']}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _filter(() {
              _categoryId = v;
              _size = null; // a size is its category's system's
            }),
          ),
        ),
        if (_models.isNotEmpty)
          sized(
            190,
            DropdownButtonFormField<String?>(
              key: const Key('pieces-model'),
              initialValue: _model,
              isExpanded: true,
              decoration: box('الموديل'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('الكل')),
                const DropdownMenuItem<String?>(value: 'none', child: Text('بلا موديل')),
                for (final m in _models)
                  if (_categoryId == null || (m['category'] as Map?)?['id'] == _categoryId)
                    DropdownMenuItem<String?>(
                      value: '${m['id']}',
                      child: Text('${m['name']}', overflow: TextOverflow.ellipsis),
                    ),
              ],
              onChanged: (v) => _filter(() => _model = v),
            ),
          ),
        if (_sizesOf(_categoryId).isNotEmpty)
          sized(
            120,
            DropdownButtonFormField<String?>(
              key: const Key('pieces-size'),
              initialValue: _size,
              isExpanded: true,
              decoration: box('المقاس'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('الكل')),
                const DropdownMenuItem<String?>(value: 'none', child: Text('بلا مقاس')),
                for (final s in _sizesOf(_categoryId))
                  DropdownMenuItem<String?>(value: '${s['id']}', child: Text('${s['label']}')),
              ],
              onChanged: (v) => _filter(() => _size = v),
            ),
          ),
        sized(
          120,
          DropdownButtonFormField<int?>(
            key: const Key('pieces-karat'),
            isExpanded: true,
            initialValue: _karat,
            decoration: box('العيار'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('الكل')),
              for (final k in _karats) DropdownMenuItem<int?>(value: k, child: Text('$k')),
            ],
            onChanged: (v) => _filter(() => _karat = v),
          ),
        ),
        sized(
          190,
          DropdownButtonFormField<int?>(
            key: const Key('pieces-place'),
            initialValue: _safeBoxId,
            isExpanded: true,
            decoration: box('المكان'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('الكل')),
              for (final s in _places)
                DropdownMenuItem<int?>(
                  value: s.id,
                  child: Text(s.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _filter(() => _safeBoxId = v),
          ),
        ),
        sized(
          190,
          DropdownButtonFormField<String>(
            key: const Key('pieces-state'),
            isExpanded: true,
            initialValue: _state,
            decoration: box('الحالة'),
            items: [
              for (final e in pieceStateLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
              const DropdownMenuItem(value: 'all', child: Text('الكل')),
            ],
            onChanged: (v) => _filter(() => _state = v ?? 'in_stock'),
          ),
        ),
      ],
    );
  }

  Widget _empty() {
    final none = ((_data?['summary'] as Map?)?['in_stock_count'] as num? ?? 0) == 0 && _state == 'in_stock';
    return AppEmptyView(
      title: none && _search.text.isEmpty ? 'لا قطع في المخزون بعد' : 'لا قطع بهذا البحث',
      hint: none ? 'القطعة تولد عند الاستلام، في «محطة ترميز القطع».' : 'غيّر البحث أو التصفية.',
      icon: Icons.diamond_outlined,
    );
  }

  Widget _table() {
    final theme = Theme.of(context);
    final columns = <(String, String?)>[
      ('رقم القطعة', 'number'),
      ('الاسم', 'name'),
      ('الموديل', null),
      ('المقاس', null),
      ('التصنيف', null),
      ('العيار', null),
      ('الوزن', 'weight'),
      ('الأحجار', null),
      ('المصنعية', null),
      ('المكان', null),
      ('الحالة', null),
      ('الاستلام', null),
      ('البطاقة', null),
      ('', null),
    ];
    final sortIndex = columns.indexWhere((c) => c.$2 == _sort);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: DataTable(
              key: const Key('pieces-table'),
              sortColumnIndex: sortIndex < 0 ? null : sortIndex,
              sortAscending: _ascending,
              showCheckboxColumn: false,
              columnSpacing: AppSpace.xl,
              horizontalMargin: AppSpace.lg,
              headingRowColor: WidgetStatePropertyAll(theme.colorScheme.surfaceContainerHigh),
              columns: [
                for (final (label, key) in columns)
                  DataColumn(
                    label: Text(label, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                    onSort: key == null ? null : (_, _) => _sortBy(key),
                  ),
              ],
              rows: [
                for (final p in _pieces)
                  DataRow(
                    key: ValueKey('piece-row-${p['item_code']}'),
                    onSelectChanged: (_) => _open(p, wide: true),
                    cells: [
                      DataCell(
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          _choose(p),
                          _ltr(
                            '${p['item_code']}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ]),
                      ),
                      DataCell(Text('${p['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      DataCell(Text(_modelOf(p))),
                      DataCell(_ltr(_sizeOf(p))),
                      DataCell(Text('${p['category_name'] ?? '—'}')),
                      DataCell(_karatChip(p['karat'])),
                      DataCell(Text('${_weight(p['weight'])} جم', style: const TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text((p['stones_weight'] as num? ?? 0) > 0 ? '${_weight(p['stones_weight'])} جم' : '—')),
                      DataCell(
                        _wage(p) == null
                            ? Text('بانتظار الفاتورة', style: theme.textTheme.bodySmall)
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${_wage(p)} ر.س', style: const TextStyle(fontWeight: FontWeight.w700)),
                                  Text('${_perGram(p)} للجرام', style: theme.textTheme.bodySmall),
                                ],
                              ),
                      ),
                      DataCell(Text((p['location'] as Map?)?['name']?.toString() ?? '—')),
                      DataCell(_stateChip('${p['state']}')),
                      DataCell(
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _ltr(_date((p['received'] as Map?)?['date']), style: theme.textTheme.bodySmall),
                            Text(_receivedFrom(p), style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                      DataCell(PieceLabelCell(piece: p, busy: _busy.contains(p['id']), actions: _labels, compact: true)),
                      DataCell(_actions(p)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardRow(Map<String, dynamic> p) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('piece-card-${p['item_code']}'),
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => _open(p, wide: false),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.md, AppSpace.xs, AppSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${p['name'] ?? ''}',
                            maxLines: 2,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        _stateChip('${p['state']}'),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.xs,
                      children: [
                        _ltr(
                          '${p['item_code']}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        Text('· ${p['category_name'] ?? ''}', style: theme.textTheme.bodySmall),
                        if (p['size'] != null) Text('· مقاس ${_sizeOf(p)}', style: theme.textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.md,
                      runSpacing: AppSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${_weight(p['weight'])} جم',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        _karatChip(p['karat']),
                        Text(
                          _wage(p) == null ? 'المصنعية بانتظار الفاتورة' : 'مصنعية ${_wage(p)} ر.س',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text((p['location'] as Map?)?['name']?.toString() ?? '—', style: theme.textTheme.bodySmall),
                    PieceLabelCell(piece: p, busy: _busy.contains(p['id']), actions: _labels),
                  ],
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [_actions(p), _choose(p)]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pager() {
    final total = (_data?['total'] as num?)?.toInt() ?? 0;
    final from = (_page - 1) * _perPage + 1;
    final to = (from + _pieces.length - 1).clamp(from, total);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Row(
        children: [
          Expanded(child: Text('$from–$to من ${_count.format(total)} قطعة', key: const Key('pieces-pager'))),
          OutlinedButton(
            onPressed: _page > 1
                ? () {
                    setState(() => _page--);
                    _load();
                  }
                : null,
            child: const Text('السابق'),
          ),
          const SizedBox(width: AppSpace.sm),
          FilledButton(
            onPressed: to < total
                ? () {
                    setState(() => _page++);
                    _load();
                  }
                : null,
            child: const Text('التالي'),
          ),
        ],
      ),
    );
  }
}

class _PieceCard extends StatelessWidget {
  const _PieceCard({
    required this.piece,
    required this.state,
    required this.karat,
    required this.weight,
    required this.facts,
    required this.onPrint,
    this.onEdit,
  });

  final Map<String, dynamic> piece;
  final Widget state;
  final Widget karat;
  final String weight;
  final List<(String, String)> facts;
  final VoidCallback onPrint;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = '${piece['description'] ?? ''}'.trim();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          key: const Key('piece-card'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${piece['name'] ?? ''}',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                state,
              ],
            ),
            Text('${piece['item_code']} · ${piece['category_name'] ?? ''}', style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  weight,
                  textDirection: TextDirection.ltr,
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: AppSpace.xs),
                Text('جم', style: theme.textTheme.titleMedium),
                const SizedBox(width: AppSpace.sm),
                karat,
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xs),
              Text(description, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: AppSpace.md),
            for (final (label, value) in facts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs + 2),
                child: Row(
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'الوزن والعيار والتصنيف والأحجار والمصنعية حقائق استلامها، فلا تُعدَّل. يُعدَّل الاسم والوصف فقط.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpace.lg),
            Row(
              children: [
                Expanded(
                  child: FilledButton(onPressed: onPrint, child: const Text('طباعة البطاقة')),
                ),
                if (onEdit != null) ...[
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: OutlinedButton(onPressed: onEdit, child: const Text('تعديل الوصف والموديل والمقاس')),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
