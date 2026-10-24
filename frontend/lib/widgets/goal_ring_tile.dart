import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';

/// A goal as a ring and its lines (bonus study م3ز–م3ح): the percent in the
/// ring, the title, the value of its target, and up to two more lines. Used
/// by «هدفي» and by the team's goal, side by side in the race card.
class GoalRingTile extends StatelessWidget {
  const GoalRingTile({
    super.key,
    required this.title,
    required this.figure,
    required this.progress,
    required this.reached,
    this.lines = const [],
    this.emphasis,
    this.semanticsLabel,
  });

  final String title;

  /// «1,200 من 1,000 نقطة».
  final String figure;
  final double progress;
  final bool reached;

  /// A line in the gold of what is paid («المكافأة حتى الآن …»).
  final String? emphasis;
  final List<String> lines;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final tone = reached ? tones.ready : tones.info;
    final percent = '${(progress * 100).round()}%';
    return Semantics(
      label: semanticsLabel ?? '$title: $figure، $percent',
      child: Row(
        children: [
          SizedBox(
            key: const Key('goal-ring'),
            width: 58,
            height: 58,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Stack(
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
                      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800, color: tone.fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                Text(figure,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                if (emphasis != null)
                  Text(emphasis!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: tones.gold.fg, fontWeight: FontWeight.w700)),
                for (final line in lines)
                  Text(line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The team's monthly goal (bonus study م3ح) as the server says it on the
/// race's payload (`team_goal`): its employees' goals summed. None, nothing.
class TeamGoalTile extends StatelessWidget {
  const TeamGoalTile({super.key, required this.goal, required this.format});

  final Map goal;

  /// The app's one number format.
  final String Function(num) format;

  @override
  Widget build(BuildContext context) {
    final unit = '${goal['unit'] ?? ''}';
    final value = (goal['value'] as num?) ?? 0;
    final target = (goal['target'] as num?) ?? 0;
    final reached = goal['reached'] == true;
    final short = target - value;
    return GoalRingTile(
      key: const Key('team-goal'),
      title: 'هدف الفريق ${goal['period_label'] ?? ''}',
      figure: '${format(value)} من ${format(target)} $unit',
      progress: ((goal['progress'] as num?) ?? 0).toDouble(),
      reached: reached,
      lines: [
        reached ? 'بلغه الفريق' : 'ينقص الفريق ${format(short)} $unit',
        'أهداف ${goal['employees'] ?? 0} موظفين',
      ],
    );
  }
}
