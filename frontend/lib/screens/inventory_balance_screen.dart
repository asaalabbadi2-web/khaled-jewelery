import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../api_service.dart';
import '../models/inventory_models.dart';
import '../services/inventory_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../widgets/app_state_views.dart';
import 'inventory_count_screen.dart';

/// «المخزون» (INV-1, ADR-086; the owner, 6 Nov 2026: «الموقع والعيار», the
/// audit «داخل شاشة الأرصدة»): each stock location a card -- its karats and
/// its total from the books, its last approved count, the session open on it;
/// its categories by a tap -- their movement before the location is counted,
/// their balances after. The deposits with offices are a section not counted
/// (ADR-052); the employees' custody one of its own.
class InventoryBalanceScreen extends StatefulWidget {
  const InventoryBalanceScreen({super.key});

  @override
  State<InventoryBalanceScreen> createState() => _InventoryBalanceScreenState();
}

class _InventoryBalanceScreenState extends State<InventoryBalanceScreen> {
  final _svc = InventoryService(ApiService());
  StockLocations? _stock;
  Object? _error;
  bool _loading = true;

  /// The widest the page grows.
  static const double _maxWidth = 1100;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stock = await _svc.getLocations();
      if (!mounted) return;
      setState(() {
        _stock = stock;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _openCount([int? sessionId]) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InventoryCountScreen(sessionId: sessionId),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المخزون'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'تحديث',
              onPressed: _load,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openCount(),
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('جرد جديد'),
        ),
        body: _loading
            ? const AppLoadingView()
            : _error != null
            ? AppErrorView(
                title: 'تعذّر تحميل المخزون',
                error: _error,
                onRetry: _load,
              )
            : RefreshIndicator(onRefresh: _load, child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final stock = _stock!;
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.lg,
            AppSpace.lg,
            AppSpace.xxl * 3,
          ),
          children: [
            if (stock.allLocationsSession != null)
              _Banner(
                tone: tones.warning,
                icon: Icons.history_toggle_off,
                text:
                    'جلسة جرد قديمة لكل المواقع (#${stock.allLocationsSession!.id}) ما زالت مفتوحة',
                action: 'فتح الجلسة',
                onAction: () => _openCount(stock.allLocationsSession!.id),
              ),
            if (stock.violations > 0)
              _Banner(
                tone: tones.blocked,
                icon: Icons.report_outlined,
                text:
                    '${stock.violations} توزيع مخزون يخالف سطره — من الفحص الليلي',
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.lg),
              child: Row(
                children: [
                  Text(
                    'إجمالي الذهب بالعيار الرئيسي',
                    style: theme.textTheme.titleSmall,
                  ),
                  const Spacer(),
                  Text(
                    '${formatGrams(stock.grandTotalMain)} جم',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            for (final section in stock.sections)
              _Section(
                section: section,
                // the stock open; the custody and the deposits folded
                initiallyOpen: section.key == 'stock',
                onResume: _openCount,
              ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.tone,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final SemanticTone tone;
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          Icon(icon, color: tone.onContainer),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(text, style: TextStyle(color: tone.onContainer)),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.section,
    required this.initiallyOpen,
    required this.onResume,
  });

  final StockSection section;
  final bool initiallyOpen;
  final void Function(int sessionId) onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: ExpansionTile(
        initiallyExpanded: initiallyOpen,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          section.label,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        trailing: Text(
          '${formatGrams(section.totalMain)} جم',
          style: theme.textTheme.titleSmall,
        ),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 760 ? 2 : 1;
              final width =
                  (constraints.maxWidth - AppSpace.md * (columns - 1)) /
                  columns;
              return Wrap(
                spacing: AppSpace.md,
                runSpacing: AppSpace.md,
                children: [
                  for (final location in section.locations)
                    SizedBox(
                      width: width,
                      child: _LocationCard(
                        location: location,
                        counted: section.counted,
                        onResume: onResume,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({
    required this.location,
    required this.counted,
    required this.onResume,
  });

  final StockLocation location;

  /// Whether its section is counted at all -- the deposits are not.
  final bool counted;
  final void Function(int sessionId) onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final last = location.lastCount;
    final open = location.openSession;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    location.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '${formatGrams(location.totalMain)} جم',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (location.karats.isNotEmpty) ...[
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  for (final k in location.karats) _KaratChip(karat: k),
                ],
              ),
            ],
            if (location.negative) ...[
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: tones.blocked.fg),
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    'رصيد سالب في الدفاتر',
                    style: TextStyle(color: tones.blocked.fg),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            if (!counted)
              Text('لا تُجرد', style: muted)
            else
              Row(
                children: [
                  Expanded(child: Text(_lastCountText(last), style: muted)),
                  if (open != null)
                    TextButton.icon(
                      onPressed: () => onResume(open.id),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        open.status == 'closed'
                            ? 'مراجعة واعتماد'
                            : 'متابعة الجرد',
                      ),
                    ),
                ],
              ),
            if (location.categories.isNotEmpty) _Categories(location: location),
          ],
        ),
      ),
    );
  }

  static String _lastCountText(LastCount? last) {
    if (last == null) return 'لم يُجرد بعد';
    final parts = [
      if (last.approvedAt != null)
        DateFormat('yyyy-MM-dd HH:mm').format(last.approvedAt!),
      if ((last.approvedBy ?? '').isNotEmpty) last.approvedBy!,
      if ((last.entryNumber ?? '').isNotEmpty) 'القيد ${last.entryNumber}',
    ];
    return 'آخر جرد: ${parts.join(' — ')}';
  }
}

class _KaratChip extends StatelessWidget {
  const _KaratChip({required this.karat});
  final StockKarat karat;

  @override
  Widget build(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final tone = switch (karat.karat) {
      18 => tones.karat18,
      22 => tones.karat22,
      24 => tones.karat24,
      _ => tones.karat21,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        'ع${karat.karat}  ${formatGrams(karat.grams)}',
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: tone.onContainer),
      ),
    );
  }
}

/// A location's categories: their balances once it was counted, else their
/// movement since the allocations began -- «خرج» or «دخل», never a negative
/// balance (ADR-086 law 1).
class _Categories extends StatelessWidget {
  const _Categories({required this.location});
  final StockLocation location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final balances = location.categoriesAreBalances;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text('التصنيفات (${location.categories.length})'),
      subtitle: Text(
        balances
            ? 'أرصدتها بعد آخر جرد'
            : 'حركتها منذ بدء التوزيع — يُصنَّف الموقع بالجرد',
        style: muted,
      ),
      children: [
        for (final c in location.categories)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Row(
              children: [
                Expanded(child: Text(c.name)),
                Text('ع${c.karat}', style: muted),
                const SizedBox(width: AppSpace.md),
                Text(
                  balances
                      ? '${formatGrams(c.grams)} جم'
                      : '${c.grams < 0 ? 'خرج' : 'دخل'} ${formatGrams(c.grams.abs())} جم',
                ),
              ],
            ),
          ),
      ],
    );
  }
}
