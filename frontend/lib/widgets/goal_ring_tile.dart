import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';

/// How the goal tiles below it are drawn: [linear] when a goal is alone (a
/// line, not a ring), [boxed] when goals stand side by side (each on its own
/// plain ground).
class GoalTileStyle extends InheritedWidget {
  const GoalTileStyle({super.key, required this.linear, required this.boxed, required super.child});

  final bool linear;
  final bool boxed;

  static GoalTileStyle? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GoalTileStyle>();

  @override
  bool updateShouldNotify(GoalTileStyle old) => old.linear != linear || old.boxed != boxed;
}

/// A goal as a ring and its lines (bonus study م3ز–م3ح): the percent in the
/// ring, the title, the value of its target, and up to two more lines. Used
/// Below this width a goal's line puts its figures under its title.
const double goalLineOnTwoBelow = 420;

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
    this.delay = Duration.zero,
  });

  /// Before it comes in, after the tile beside it (the owner: «انيميشن عند
  /// الفتح»).
  final Duration delay;

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
    // On opening: the tile fades and slides in, the ring fills and its percent
    // counts up with it; a reload with new figures moves on from where it is.
    const enter = Duration(milliseconds: 450);
    const fill = Duration(milliseconds: 1100);
    final total = delay + fill;
    final start = delay.inMilliseconds / total.inMilliseconds;
    final style = GoalTileStyle.of(context);
    final linear = style?.linear ?? false;
    final texts = <Widget>[
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
    ];
    Widget filling(Widget Function(double v) build) => TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: progress),
          duration: total,
          curve: Interval(start, 1, curve: Curves.easeOutCubic),
          builder: (context, v, _) => build(v),
        );
    final percentStyle = theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800, color: tone.fg);

    // Alone, a ring reads poorly (the owner): a line instead, as tall as a
    // ring -- the title and figure on one line, a thin bar, and one line
    // under it: what it pays and how far; for the team, how far.
    final first = emphasis ?? (lines.isEmpty ? null : lines.first);
    final Widget body = linear
        ? Column(
            key: const Key('goal-line'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The title and its figures on one line; on a phone, the figures
              // on a line of their own (the owner, 16 Nov 2026: «2,346 من
              // 5,000 نقـ…» was cut beside the title).
              LayoutBuilder(builder: (context, box) {
                final titleText = Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant));
                final figureText = Text(figure,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800));
                final percentText = filling(
                    (v) => Text('${(v * 100).round()}%', textDirection: TextDirection.ltr, style: percentStyle));
                if (box.maxWidth < goalLineOnTwoBelow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [Expanded(child: titleText), percentText]),
                      figureText,
                    ],
                  );
                }
                return Row(children: [
                  Flexible(child: titleText),
                  Text(' · ', style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                  Expanded(child: figureText),
                  percentText,
                ]);
              }),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: filling((v) => LinearProgressIndicator(
                      value: v.clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: cs.outlineVariant.withValues(alpha: 0.6),
                      valueColor: AlwaysStoppedAnimation<Color>(tone.fg),
                    )),
              ),
              if (first != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Flexible(
                    child: Text(first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: first == emphasis ? tones.gold.fg : cs.onSurfaceVariant,
                          fontWeight: first == emphasis ? FontWeight.w700 : null,
                        )),
                  ),
                  // What it pays first; how far beside it, on the same line.
                  if (emphasis != null && lines.isNotEmpty) ...[
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(lines.first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                  ],
                ]),
              ],
            ],
          )
        : Row(
            children: [
              SizedBox(
                key: const Key('goal-ring'),
                width: 58,
                height: 58,
                child: filling((v) => Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: v.clamp(0.0, 1.0),
                          strokeWidth: 6,
                          strokeCap: StrokeCap.round,
                          backgroundColor: cs.outlineVariant.withValues(alpha: 0.6),
                          valueColor: AlwaysStoppedAnimation<Color>(tone.fg),
                        ),
                        Center(
                          child: Text('${(v * 100).round()}%',
                              textDirection: TextDirection.ltr, style: percentStyle),
                        ),
                      ],
                    )),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: texts,
                ),
              ),
            ],
          );
    // Beside another, each on a plain ground of its own (the owner: «بخلفية
    // بسيطة لتحقق العزل البصري بين الحلقتين»).
    final tile = Semantics(
      label: semanticsLabel ?? '$title: $figure، $percent',
      child: (style?.boxed ?? false)
          ? Container(
              key: const Key('goal-ground'),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: body,
            )
          : body,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: delay + enter,
      curve: Interval(delay.inMilliseconds / (delay + enter).inMilliseconds, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
      ),
      child: tile,
    );
  }
}

/// The team's goal as the server says it on the race's payload
/// (`team_goal`, bonus study م3ح): the month's, its employees' goals summed;
/// the week's, its share of the month's. None, nothing.
class TeamGoalTile extends StatelessWidget {
  const TeamGoalTile({super.key, required this.goal, required this.format, this.delay = Duration.zero});

  final Map goal;

  /// It comes in after «هدفي» beside it.
  final Duration delay;

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
      delay: delay,
      lines: [
        reached ? 'بلغه الفريق' : 'ينقص الفريق ${format(short)} $unit',
        // The month's is its employees' goals; the week's its share of them.
        goal['share_of'] == 'monthly'
            ? 'حصة الأسبوع من أهداف ${goal['employees']} موظفين'
            : 'أهداف ${goal['employees']} موظفين',
      ],
    );
  }
}
