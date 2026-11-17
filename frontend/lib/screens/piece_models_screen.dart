import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_views.dart';
import 'model_stock_grid_screen.dart';
import 'piece_model_form_screen.dart';

/// «الموديلات» (ADR-093 M1; the owner, 17 Nov 2026): the models the pieces
/// share -- each with its photo, its supplier's code, its expected wage, the
/// sizes it comes in and how many pieces are of it. Filtered by category,
/// searched by name or code; the stopped ones on asking.
class PieceModelsScreen extends StatefulWidget {
  const PieceModelsScreen({super.key, required this.api, this.pickPhoto = pickModelPhoto});

  final ApiService api;
  final PhotoPicker pickPhoto;

  @override
  State<PieceModelsScreen> createState() => _PieceModelsScreenState();
}

class _PieceModelsScreenState extends State<PieceModelsScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _models;
  // a category chosen: its board -- each model's stock size by size, and «بلا موديل» (M4)
  Map<String, dynamic>? _board;
  List<Map<String, dynamic>> _categories = const [];
  int? _categoryId;
  bool _stopped = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await widget.api.getCategories();
      if (!mounted) return;
      setState(() => _categories = [
            for (final c in categories)
              if ((c as Map)['is_scrap'] != true) Map<String, dynamic>.from(c),
          ]);
    } catch (_) {
      // the filter is offered without its categories
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final categoryId = _categoryId;
      if (categoryId != null) {
        final board = await widget.api.getModelsBoard(categoryId);
        final text = _search.text.trim();
        final models = [
          for (final m in board['models'] as List)
            if (text.isEmpty ||
                '${(m as Map)['name']}'.contains(text) ||
                '${m['supplier_code'] ?? ''}'.contains(text))
              if (_stopped || m['is_active'] != false) Map<String, dynamic>.from(m),
        ];
        if (mounted) {
          setState(() {
            _board = board;
            _models = models;
          });
        }
        return;
      }
      final models = await widget.api.getPieceModels(q: _search.text, includeInactive: _stopped);
      if (mounted) {
        setState(() {
          _board = null;
          _models = models;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open({int? modelId}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PieceModelFormScreen(
          api: widget.api,
          modelId: modelId,
          categoryId: _categoryId,
          pickPhoto: widget.pickPhoto,
        ),
      ),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الموديلات'),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpace.sm),
            child: TextButton.icon(
              key: const Key('models-new'),
              onPressed: () => _open(),
              icon: const Icon(Icons.add),
              label: const Text('موديل جديد'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 0),
            child: Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: TextField(
                    key: const Key('models-search'),
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'بحث',
                      hintText: 'اسم الموديل أو رمز المورد',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<int?>(
                    key: const Key('models-category'),
                    initialValue: _categoryId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'التصنيف'),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('كل التصنيفات')),
                      for (final c in _categories)
                        DropdownMenuItem<int?>(value: c['id'] as int, child: Text('${c['name']}')),
                    ],
                    onChanged: (v) {
                      setState(() => _categoryId = v);
                      _load();
                    },
                  ),
                ),
                FilterChip(
                  key: const Key('models-stopped'),
                  selected: _stopped,
                  label: const Text('والموقوفة'),
                  onSelected: (v) {
                    setState(() => _stopped = v);
                    _load();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Expanded(child: _list(context)),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (_error != null) {
      return AppErrorView(title: 'تعذّر تحميل الموديلات', error: _error, onRetry: _load);
    }
    final models = _models;
    if (models == null) return const AppLoadingView(summaryBlocks: 1);
    final board = _board;
    if (models.isEmpty && board == null) {
      return AppEmptyView(
        title: 'لا موديلات بعد',
        hint: 'الموديل يجمع ما تشترك فيه قطعه: الشكل، والأجرة المتوقّعة، والمقاسات، والصورة.',
        icon: Icons.style_outlined,
        actionLabel: 'موديل جديد',
        actionIcon: Icons.add,
        onAction: () => _open(),
      );
    }
    final cards = <Widget>[
      for (final m in models)
        _ModelCard(
          model: m,
          onOpen: () => _open(modelId: m['id'] as int),
          onSizes: board == null ? null : () => _grid(modelId: m['id'] as int, title: '${m['name']}'),
        ),
      if (board != null)
        _NoModelCard(
          row: Map<String, dynamic>.from(board['no_model'] as Map),
          onOpen: () => _grid(categoryId: _categoryId, title: 'بلا موديل'),
        ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = (box.maxWidth / 300).floor().clamp(1, 5);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
                child: board == null
                    ? Text('اختر تصنيفًا لترى ما في المخزون من كل موديل ومقاس.',
                        style: Theme.of(context).textTheme.bodySmall)
                    : _BoardSummary(board: board),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpace.md,
                  crossAxisSpacing: AppSpace.md,
                  mainAxisExtent: board == null ? 330 : 400,
                ),
                delegate: SliverChildListDelegate(cards),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _grid({int? modelId, int? categoryId, required String title}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelStockGridScreen(api: widget.api, modelId: modelId, categoryId: categoryId, title: title),
      ),
    );
    if (mounted) _load();
  }
}

/// The category's line: its models' pieces and those with no model, adding up
/// to its stock -- every figure the server's.
class _BoardSummary extends StatelessWidget {
  const _BoardSummary({required this.board});

  final Map<String, dynamic> board;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inModels = board['in_models'] as Map;
    final noModel = board['no_model'] as Map;
    final total = board['in_stock'] as Map;
    final sizes = [for (final s in board['sizes'] as List? ?? const []) '${(s as Map)['label']}'];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Wrap(
          spacing: AppSpace.lg,
          runSpacing: AppSpace.xs,
          children: [
            Text('${(board['category'] as Map)['name']}', style: theme.textTheme.titleMedium),
            Text(
              '${inModels['count']} قطعة في ${board['models_count']} موديلات + ${noModel['count']} بلا موديل '
              '= ${total['count']} قطعة · ${total['weight']} جم — رصيد التصنيف',
              key: const Key('board-summary'),
            ),
            if (sizes.isNotEmpty) Text('المقاسات: ${sizes.join(' · ')}', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// The size chips of a board's row: each size and its pieces; none -- run out.
class _SizeChips extends StatelessWidget {
  const _SizeChips({required this.rows});

  final List rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Wrap(
      spacing: AppSpace.xs,
      runSpacing: AppSpace.xs,
      children: [
        for (final r in rows)
          Container(
            key: Key('size-chip-${((r as Map)['size'] as Map?)?['label'] ?? 'none'}'),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
            decoration: BoxDecoration(
              color: (r['count'] as int? ?? 0) == 0 ? cs.errorContainer : cs.secondaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Text(
              '${(r['size'] as Map?)?['label'] ?? 'بلا مقاس'} · ${r['count']}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: (r['count'] as int? ?? 0) == 0 ? cs.onErrorContainer : cs.onSecondaryContainer,
              ),
            ),
          ),
      ],
    );
  }
}

class _NoModelCard extends StatelessWidget {
  const _NoModelCard({required this.row, required this.onOpen});

  final Map<String, dynamic> row;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('board-no-model'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('بلا موديل', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.xs),
            Text('قطع التصنيف التي لم تُربط بموديل — تظهر هنا حتى يساوي المجموع رصيد التصنيف.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpace.sm),
            Text('${row['count']} قطع · ${row['weight']} جم', style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpace.sm),
            _SizeChips(rows: row['by_size'] as List? ?? const []),
            const Spacer(),
            OutlinedButton(
              key: const Key('board-no-model-open'),
              onPressed: (row['count'] as int? ?? 0) == 0 ? null : onOpen,
              child: const Text('القطع'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.model, required this.onOpen, this.onSizes});

  final Map<String, dynamic> model;
  final VoidCallback onOpen;
  final VoidCallback? onSizes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final wage = model['expected_wage_per_gram'];
    final sizes = [for (final s in model['sizes'] as List? ?? const []) '${(s as Map)['label']}'];
    final stopped = model['is_active'] == false;
    return Card(
      key: Key('model-card-${model['id']}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModelImage(uri: model['thumbnail'] as String?, height: 140),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${model['name']}',
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (stopped)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text('موقوف', style: theme.textTheme.labelSmall),
                          ),
                      ],
                    ),
                    Text(
                      '${(model['category'] as Map?)?['name'] ?? ''}'
                      '${model['supplier_code'] == null ? '' : ' · ${model['supplier_code']}'}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      '${wage == null ? 'بلا أجرة متوقّعة' : 'أجرة متوقّعة $wage للجرام'} · ${model['pieces'] ?? 0} قطعة',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpace.sm),
                    if (model['by_size'] != null) ...[
                      Text(
                        '${(model['stock'] as Map)['count']} قطعة · ${(model['stock'] as Map)['weight']} جم في المخزون',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: AppSpace.xs),
                      _SizeChips(rows: model['by_size'] as List),
                      if ((model['missing'] as List? ?? const []).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Text(
                            'نفد: ${(model['missing'] as List).join(' · ')}',
                            key: Key('model-missing-${model['id']}'),
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.error, fontWeight: FontWeight.w700),
                          ),
                        ),
                      const Spacer(),
                      if (onSizes != null)
                        FilledButton(
                          key: Key('model-sizes-${model['id']}'),
                          onPressed: onSizes,
                          child: const Text('المقاسات والقطع'),
                        ),
                    ] else
                    Expanded(
                      child: sizes.isEmpty
                          ? Text('بلا مقاسات', style: theme.textTheme.bodySmall)
                          : Wrap(
                              spacing: AppSpace.xs,
                              runSpacing: AppSpace.xs,
                              children: [
                                for (final s in sizes)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: cs.secondaryContainer,
                                      borderRadius: BorderRadius.circular(AppRadius.pill),
                                    ),
                                    child: Text(
                                      s,
                                      textDirection: TextDirection.ltr,
                                      style: theme.textTheme.labelMedium?.copyWith(color: cs.onSecondaryContainer),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
