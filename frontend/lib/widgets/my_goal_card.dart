import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_tokens.dart';
import '../utils/currency_utils.dart' as cu;
import 'app_feedback.dart';
import 'app_state_views.dart';
import 'goal_ring_tile.dart';

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
  const MyGoalCard({
    super.key,
    required this.api,
    this.framed = true,
    this.alongside,
    this.refreshedAt,
    this.periods,
  });

  /// The goals' periods shown ('daily', 'weekly', 'monthly'): the race
  /// card's own period (the owner: «يتم التبديل بين الأسبوع والشهر حسب
  /// الفترة»). Null: all.
  final Set<String>? periods;

  final ApiService api;
  final bool framed;

  /// When the card around it last loaded: a new one reloads the goals with
  /// it, so they live and end with the card's other figures -- they stayed
  /// shown, from the first load, after the session had ended.
  final Object? refreshedAt;

  /// Beside the goals in the same row (the owner: «في صف واحد وليس في
  /// عمود») -- the team's goal in the race card. Shown alone without a goal.
  final Widget? alongside;

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

  @override
  void didUpdateWidget(MyGoalCard old) {
    super.didUpdateWidget(old);
    if (widget.refreshedAt != old.refreshedAt) _load(quietly: true);
  }

  /// [quietly]: the figures shown stay until the new ones come.
  Future<void> _load({bool quietly = false}) async {
    if (!quietly) {
      setState(() {
        _goals = null;
        _error = null;
      });
    }
    try {
      final goals = await widget.api.getMyGoalProgress();
      if (mounted) {
        setState(() {
          _goals = goals;
          _error = null;
        });
      }
    } on ApiAuthException {
      // The session ended: nothing of it is shown, as the card's figures go.
      if (mounted) {
        setState(() {
          _goals = const [];
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _goals = null;
          _error = e;
        });
      }
    }
  }

  static String _n(num v) => cu.formatAmount(v, decimals: v == v.truncate() ? 0 : 2);

  Widget _frame(Widget child) => widget.framed
      ? Card(child: Padding(padding: const EdgeInsets.all(AppSpace.lg), child: child))
      : Padding(padding: const EdgeInsets.only(bottom: AppSpace.md), child: child);

  /// One goal alone is a line; two or more stand side by side, each on its
  /// own ground (the owner, 24 Oct 2026).
  Widget _row(List<Widget> tiles) => tiles.length == 1
      ? GoalTileStyle(linear: true, boxed: false, child: tiles.single)
      : GoalTileStyle(
          linear: false,
          boxed: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, tile) in tiles.indexed) ...[
                if (i > 0) const SizedBox(width: AppSpace.md),
                Expanded(child: tile),
              ],
            ],
          ),
        );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alongside = widget.alongside;
    if (_error != null) {
      final failed = Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text('تعذّر تحميل هدفك: ${AppFeedback.messageOf(_error!)}', style: theme.textTheme.bodySmall),
          ),
          TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
        ],
      );
      return _frame(alongside == null ? failed : _row([failed, alongside]));
    }
    final goals = _goals;
    if (goals == null && widget.framed) {
      return const Card(child: SizedBox(height: 120, child: AppLoadingView(summaryBlocks: 1, rows: 1)));
    }
    final tiles = [
      for (final g in goals ?? const <Map<String, dynamic>>[])
        if (widget.periods == null || widget.periods!.contains(g['period'])) _goal(context, g),
    ];
    if (alongside != null) tiles.add(alongside);
    if (tiles.isEmpty) return const SizedBox.shrink();
    return _frame(_row(tiles));
  }

  Widget _goal(BuildContext context, Map<String, dynamic> g) {
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final unit = '${g['unit'] ?? ''}';
    final value = (g['value'] as num?) ?? 0;
    final target = (g['target'] as num?) ?? 0;
    final reached = g['reached'] == true;
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
    return GoalRingTile(
      key: Key('my-goal-${g['period']}'),
      title: 'هدفي ${g['period_label'] ?? ''}',
      figure: '${_n(value)} من ${_n(target)} $unit',
      progress: ((g['progress'] as num?) ?? 0).toDouble(),
      reached: reached,
      emphasis: 'المكافأة حتى الآن ${cu.formatAmount((g['amount_so_far'] as num?) ?? 0)} $currency',
      lines: [?nextLine],
    );
  }
}
