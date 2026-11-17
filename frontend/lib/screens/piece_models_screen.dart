import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_views.dart';
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
      final models = await widget.api.getPieceModels(
        categoryId: _categoryId,
        q: _search.text,
        includeInactive: _stopped,
      );
      if (mounted) setState(() => _models = models);
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
    if (models.isEmpty) {
      return AppEmptyView(
        title: 'لا موديلات بعد',
        hint: 'الموديل يجمع ما تشترك فيه قطعه: الشكل، والأجرة المتوقّعة، والمقاسات، والصورة.',
        icon: Icons.style_outlined,
        actionLabel: 'موديل جديد',
        actionIcon: Icons.add,
        onAction: () => _open(),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final columns = (box.maxWidth / 300).floor().clamp(1, 5);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpace.md,
            crossAxisSpacing: AppSpace.md,
            mainAxisExtent: 330,
          ),
          itemCount: models.length,
          itemBuilder: (context, i) => _ModelCard(
            model: models[i],
            onOpen: () => _open(modelId: models[i]['id'] as int),
          ),
        );
      },
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.model, required this.onOpen});

  final Map<String, dynamic> model;
  final VoidCallback onOpen;

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
