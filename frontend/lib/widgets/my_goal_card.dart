import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/currency_utils.dart' as cu;
import 'app_feedback.dart';
import 'app_state_views.dart';

/// «هدفي» (bonus study م3; ADR-058): the signed-in employee's goals so far as
/// the server says them -- the value, the target (its rule's threshold), what
/// its rule pays so far, and how far the next tier is. The number shown is
/// the one that will be paid; the widget computes none of it. No goal, nothing.
///
/// Each goal is a ring -- the race's other progress is linear -- beside its
/// figures (the owner, 24 Oct 2026: «تدمج بنفس بطاقة الأداء ... مع شريط تقدم
/// دائري»). [framed]: a card of its own, where the race card is not shown;
/// otherwise a strip inside the race card.
class MyGoalCard extends StatefulWidget {
  const MyGoalCard({super.key, required this.api, this.framed = true});

  final ApiService api;
  final bool framed;

  @override
  State<MyGoalCard> createState() => _MyGoalCardState();
}

class _MyGoalCardState extends State<MyGoalCard> {
  List<Map<String, dynamic>>? _goals;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _goals = null;
      _error = null;
    });
    try {
      final goals = await widget.api.getMyGoalProgress();
      if (mounted) setState(() => _goals = goals);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static String _n(num v) => cu.formatAmount(v, decimals: v == v.truncate() ? 0 : 2);

  Widget _frame(Widget child) => widget.framed
      ? Card(child: Padding(padding: const EdgeInsets.all(AppSpace.lg), child: child))
      : Padding(padding: const EdgeInsets.only(bottom: AppSpace.md), child: child);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return _frame(Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text('تعذّر تحميل هدفك: ${AppFeedback.messageOf(_error!)}', style: theme.textTheme.bodySmall),
          ),
          TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
        ],
      ));
    }
    final goals = _goals;
    if (goals == null && widget.framed) {
      return const Card(child: SizedBox(height: 120, child: AppLoadingView(summaryBlocks: 1, rows: 1)));
    }
    if (goals == null || goals.isEmpty) return const SizedBox.shrink();
    return _frame(Wrap(
      spacing: AppSpace.lg,
      runSpacing: AppSpace.md,
      children: [for (final g in goals) _goal(context, g)],
    ));
  }

  Widget _goal(BuildContext context, Map<String, dynamic> g) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final unit = '${g['unit'] ?? ''}';
    final value = (g['value'] as num?) ?? 0;
    final target = (g['target'] as num?) ?? 0;
    final progress = ((g['progress'] as num?) ?? 0).toDouble();
    final reached = g['reached'] == true;
    final tone = reached ? tones.ready : tones.info;
    final next = g['next_tier'] as Map?;
    final toNext = g['to_next'] as num?;
    String? nextLine;
    if (next != null && toNext != null) {
      final rate = next['per_unit'] != null
          ? '${_n(next['per_unit'] as num)} لكل $unit'
          : '${_n(next['amount'] as num)} $currency';
      nextLine = reached
          ? 'ينقصك ${_n(toNext)} $unit لشريحة ${_n(next['from'] as num)} ($rate)'
          : 'ينقصك ${_n(toNext)} $unit لبلوغ هدفك';
    } else if (reached) {
      nextLine = 'بلغت أعلى شريحة';
    }
    final percent = '${(progress * 100).round()}%';
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 420),
      child: Semantics(
        label: 'هدفي ${g['period_label'] ?? ''}: ${_n(value)} من ${_n(target)} $unit، $percent',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: const Key('my-goal-ring'),
              width: 64,
              height: 64,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => Stack(
                  alignment: Alignment.center,
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      value: v,
                      strokeWidth: 6,
                      strokeCap: StrokeCap.round,
                      backgroundColor: cs.outlineVariant.withValues(alpha: 0.6),
                      valueColor: AlwaysStoppedAnimation<Color>(tone.fg),
                    ),
                    Center(
                      child: Text(
                        percent,
                        textDirection: TextDirection.ltr,
                        style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: tone.fg),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('هدفي ${g['period_label'] ?? ''}',
                      style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                  Text(
                    '${_n(value)} من ${_n(target)} $unit',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'المكافأة حتى الآن ${cu.formatAmount((g['amount_so_far'] as num?) ?? 0)} $currency',
                    style: theme.textTheme.bodySmall?.copyWith(color: tones.gold.fg, fontWeight: FontWeight.w700),
                  ),
                  if (nextLine != null)
                    Text(nextLine, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
