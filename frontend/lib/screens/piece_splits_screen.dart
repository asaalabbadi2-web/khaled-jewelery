import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import '../utils/display_date.dart';
import '../widgets/app_state_views.dart';

/// «سجلّ التفكيك» (ADR-099; the owner, 23 Nov 2026): every split, the newest
/// first -- the piece and its weight, who split it, when and why, into what,
/// and the difference left on the shortage or the surplus. For a manager's
/// review: a split on paper -- the set left whole in its showcase, its label
/// taken off -- shows here and in a count by weight, nowhere else.
class PieceSplitsScreen extends StatefulWidget {
  const PieceSplitsScreen({super.key, required this.api});
  final ApiService api;

  @override
  State<PieceSplitsScreen> createState() => _PieceSplitsScreenState();
}

class _PieceSplitsScreenState extends State<PieceSplitsScreen> {
  List<Map<String, dynamic>>? _splits;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final splits = await widget.api.pieceSplits();
      if (mounted) setState(() => _splits = splits);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _grams(num v) => ltrIsolate('${formatGrams(v, decimals: 2)} جم');

  Widget _card(BuildContext context, Map<String, dynamic> s) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final difference = (s['difference'] as num?) ?? 0;
    final parts = (s['parts'] as List? ?? const []).cast<Map<String, dynamic>>();
    return Card(
      key: ValueKey('split-${s['id']}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.call_split, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(isolateLatin('${s['item_code']} · ${s['category_name'] ?? ''} · ${_grams(s['weight'] as num? ?? 0)}'),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            isolateLatin('${displayDateTime(s['split_at'])} · ${s['split_by_name'] ?? s['split_by']} · القيد ${s['entry_number'] ?? '—'}'),
            key: ValueKey('split-who-${s['id']}'),
            style: theme.textTheme.bodySmall,
          ),
          Text('السبب: ${s['reason']}', style: theme.textTheme.bodySmall),
          const Divider(height: 18),
          for (final p in parts)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Icon(p['item_code'] != null ? Icons.sell_outlined : Icons.scale_outlined, size: 16,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(isolateLatin('${p['category_name']} · ${_grams(p['weight'] as num? ?? 0)}'
                      '${p['item_code'] != null ? ' · قطعة ${p['item_code']}' : ' · وزنًا في تصنيفه'}'
                      ' · أجرة ${formatAmount(p['wage'] as num? ?? 0)}')),
                ),
              ]),
            ),
          if (difference != 0)
            Text(
              isolateLatin(difference < 0
                  ? 'فرق ${_grams(-difference)} سُجّل خسارة وزن'
                  : 'زيادة ${_grams(difference)} سُجّلت زيادة جرد'),
              key: ValueKey('split-difference-${s['id']}'),
              style: theme.textTheme.bodySmall?.copyWith(color: tones.warning.fg, fontWeight: FontWeight.w700),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final splits = _splits;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سجلّ التفكيك'),
          actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'تحديث', onPressed: _load)],
        ),
        body: _error != null && splits == null
            ? AppErrorView(title: 'تعذّر تحميل سجلّ التفكيك', error: _error!, onRetry: _load)
            : splits == null
                ? const AppLoadingView()
                : splits.isEmpty
                    ? const AppEmptyView(
                        title: 'لم تُفكَّك قطعة بعد',
                        hint: 'تُفكَّك القطعة من «القطع» أو من فاتورة البيع «بيع جزء منه»، وكل تفكيك يُسجَّل هنا.',
                        icon: Icons.call_split,
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 720),
                                child: Column(children: [for (final s in splits) _card(context, s)]),
                              ),
                            ),
                          ],
                        ),
                      ),
      ),
    );
  }
}
