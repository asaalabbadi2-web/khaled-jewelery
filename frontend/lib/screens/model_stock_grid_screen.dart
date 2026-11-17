import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../api_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_views.dart';
import 'piece_model_form_screen.dart' show ModelImage;

/// «مقاسات الموديل» (ADR-093 M4; the owner, 17 Nov 2026): what is in stock of
/// a model -- or of a category with no model -- size by size: each size its
/// pieces and grams, its lightest and heaviest, what has run out; a size
/// opened, its pieces lightest first with their place. What is asked at the
/// counter: «this shape in 18».
class ModelStockGridScreen extends StatefulWidget {
  const ModelStockGridScreen({super.key, required this.api, this.modelId, this.categoryId, this.title});

  final ApiService api;
  final int? modelId;
  final int? categoryId;
  final String? title;

  @override
  State<ModelStockGridScreen> createState() => _ModelStockGridScreenState();
}

class _ModelStockGridScreenState extends State<ModelStockGridScreen> {
  Map<String, dynamic>? _grid;
  Object? _error;
  final _grams = NumberFormat('#,##0.00', 'en');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final grid = await widget.api.getStockGrid(modelId: widget.modelId, categoryId: widget.categoryId);
      if (mounted) setState(() => _grid = grid);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _g(Object? v) => _grams.format((v as num?) ?? 0);

  @override
  Widget build(BuildContext context) {
    final model = _grid?['model'] as Map?;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? '${model?['name'] ?? 'بلا موديل'}')),
      body: _error != null
          ? AppErrorView(title: 'تعذّر تحميل المقاسات', error: _error, onRetry: _load)
          : _grid == null
              ? const AppLoadingView(summaryBlocks: 1)
              : RefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final grid = _grid!;
    final model = grid['model'] as Map?;
    final stock = Map<String, dynamic>.from(grid['stock'] as Map);
    final rows = [for (final r in grid['by_size'] as List) Map<String, dynamic>.from(r as Map)];
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    child: ModelImage(api: widget.api, attachmentId: model?['thumbnail_id'] as int?),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${(grid['category'] as Map)['name']}', style: theme.textTheme.bodySmall),
                      Text(
                        '${stock['count']} قطعة · ${_g(stock['weight'])} جم',
                        key: const Key('grid-total'),
                        style: theme.textTheme.titleMedium,
                      ),
                      if (model?['expected_wage_per_gram'] != null)
                        Text('أجرة متوقّعة ${model!['expected_wage_per_gram']} للجرام', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        if (rows.isEmpty)
          const AppEmptyView(title: 'لا قطع في المخزون', icon: Icons.inventory_2_outlined)
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final r in rows)
                  _row(context, r, out: (r['count'] as int? ?? 0) == 0, cs: cs),
              ],
            ),
          ),
        const SizedBox(height: AppSpace.sm),
        Text('القطع مرتبة بالوزن، الأخف أولًا. البيع بمسح رقاقة القطعة.', style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> r, {required bool out, required ColorScheme cs}) {
    final theme = Theme.of(context);
    final size = r['size'] as Map?;
    final label = size == null ? 'بلا مقاس' : '${size['label']}';
    final pieces = [for (final p in r['pieces'] as List? ?? const []) Map<String, dynamic>.from(p as Map)];
    final title = Text(label, textDirection: TextDirection.ltr, style: theme.textTheme.titleMedium);
    if (out) {
      return ListTile(
        key: Key('grid-size-${size?['id'] ?? 'none'}'),
        tileColor: cs.errorContainer,
        title: title,
        subtitle: Text('نفد', style: TextStyle(color: cs.onErrorContainer)),
      );
    }
    return ExpansionTile(
      key: Key('grid-size-${size?['id'] ?? 'none'}'),
      title: title,
      subtitle: Text('${r['count']} قطع · ${_g(r['weight'])} جم'),
      trailing: Text(
        '${_g(r['lightest'])} – ${_g(r['heaviest'])}',
        textDirection: TextDirection.ltr,
        style: theme.textTheme.bodySmall,
      ),
      children: [
        for (final p in pieces)
          ListTile(
            key: Key('grid-piece-${p['item_code']}'),
            dense: true,
            title: Text('${_g(p['weight'])} جم', textDirection: TextDirection.ltr, textAlign: TextAlign.start),
            subtitle: Text('${p['item_code']}', textDirection: TextDirection.ltr, textAlign: TextAlign.start),
            trailing: Text('${(p['location'] as Map?)?['name'] ?? '—'}', style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}
