import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Beside an employee in the race (bonus study م3هـ; the owner, 24 Oct 2026):
/// a crown with the months they led, a target with the periods they reached
/// their goal -- as the server kept them when each period closed. None, no
/// badge. Plain, in one quiet colour (the owner: «تصميمها ولونها بسيط»): a
/// line icon and its number, no fill.
class RaceHonoursBadges extends StatelessWidget {
  const RaceHonoursBadges({super.key, required this.crowns, required this.goalsReached});

  /// Reads the counters off a race row ({crowns, goals_reached}).
  factory RaceHonoursBadges.of(Map row, {Key? key}) => RaceHonoursBadges(
        key: key,
        crowns: (row['crowns'] as num?)?.toInt() ?? 0,
        goalsReached: (row['goals_reached'] as num?)?.toInt() ?? 0,
      );

  final int crowns;
  final int goalsReached;

  @override
  Widget build(BuildContext context) {
    if (crowns <= 0 && goalsReached <= 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (crowns > 0)
          _Badge(
            key: const Key('race-crowns'),
            icon: (color, size) => CustomPaint(size: Size.square(size), painter: _CrownPainter(color)),
            count: crowns,
            says: crowns == 1 ? 'تصدّر السباق شهرًا' : 'تصدّر السباق $crowns أشهر',
          ),
        if (crowns > 0 && goalsReached > 0) const SizedBox(width: AppSpace.sm),
        if (goalsReached > 0)
          _Badge(
            key: const Key('race-goals'),
            icon: (color, size) => Icon(Icons.track_changes_rounded, size: size, color: color),
            count: goalsReached,
            says: goalsReached == 1 ? 'بلغ هدفه مرة' : 'بلغ هدفه $goalsReached مرات',
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.icon, required this.count, required this.says});

  final Widget Function(Color color, double size) icon;
  final int count;
  final String says;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: says,
      child: Semantics(
        label: says,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon(color, 14),
            const SizedBox(width: 2),
            Text(
              '$count',
              textDirection: TextDirection.ltr,
              style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// A crown in one line: a base and three points.
class _CrownPainter extends CustomPainter {
  _CrownPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.11
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final crown = Path()
      ..moveTo(w * 0.14, h * 0.78)
      ..lineTo(w * 0.10, h * 0.30)
      ..lineTo(w * 0.34, h * 0.52)
      ..lineTo(w * 0.50, h * 0.20)
      ..lineTo(w * 0.66, h * 0.52)
      ..lineTo(w * 0.90, h * 0.30)
      ..lineTo(w * 0.86, h * 0.78)
      ..close();
    canvas.drawPath(crown, stroke);
  }

  @override
  bool shouldRepaint(_CrownPainter old) => old.color != color;
}
