import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' as cu;
import 'app_feedback.dart';
import 'app_state_views.dart';

/// «هدفي» (bonus study م3; ADR-058): the signed-in employee's goals so far as
/// the server says them -- the value, the target (its rule's threshold), what
/// its rule pays so far, and how far the next tier is. The number shown is
/// the one that will be paid; the card computes none of it. No goal, no card.
class MyGoalCard extends StatefulWidget {
  const MyGoalCard({super.key, required this.api});

  final ApiService api;

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

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      final theme = Theme.of(context);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text('تعذّر تحميل هدفك: ${AppFeedback.messageOf(_error!)}',
                    style: theme.textTheme.bodyMedium),
              ),
              TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
            ],
          ),
        ),
      );
    }
    final goals = _goals;
    if (goals == null) {
      return const Card(child: SizedBox(height: 140, child: AppLoadingView(summaryBlocks: 1, rows: 1)));
    }
    if (goals.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < goals.length; i++) ...[
              if (i > 0) const Divider(height: 24),
              _goal(context, goals[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _goal(BuildContext context, Map<String, dynamic> g) {
    final theme = Theme.of(context);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('هدفي ${g['period_label'] ?? ''}', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                '${_n(value)} من ${_n(target)} $unit',
                style: theme.textTheme.titleLarge?.copyWith(color: tone.fg),
              ),
            ),
            Text('${(progress * 100).round()}%', style: theme.textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 8,
            color: tone.fg,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'المكافأة حتى الآن ${cu.formatAmount((g['amount_so_far'] as num?) ?? 0)} $currency',
          style: theme.textTheme.bodyLarge,
        ),
        if (nextLine != null) ...[
          const SizedBox(height: 4),
          Text(nextLine, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}
