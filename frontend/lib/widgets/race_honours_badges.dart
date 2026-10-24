import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Beside an employee in the race (bonus study م3هـ; the owner, 24 Oct 2026):
/// a crown with the months they led, a target with the periods they reached
/// their goal -- as the server kept them when each period closed. None, no
/// badge. A filled crown and a target struck by an arrow (the owner's
/// drawing, 24 Oct 2026), in one quiet colour with their number (the owner:
/// «أعد لون الأيقونة كما كان») -- the text's secondary colour, no fill.
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
            icon: (size) => CustomPaint(
              size: Size.square(size),
              painter: RaceCrownPainter(
                gold: Theme.of(context).colorScheme.onSurfaceVariant,
                shade: Theme.of(context).colorScheme.shadow,
              ),
            ),
            count: crowns,
            says: crowns == 1 ? 'تصدّر السباق شهرًا' : 'تصدّر السباق $crowns أشهر',
          ),
        if (crowns > 0 && goalsReached > 0) const SizedBox(width: AppSpace.sm),
        if (goalsReached > 0)
          _Badge(
            key: const Key('race-goals'),
            icon: (size) => CustomPaint(
              size: Size.square(size),
              painter: RaceTargetPainter(
                rings: Theme.of(context).colorScheme.onSurfaceVariant,
                arrow: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            count: goalsReached,
            says: goalsReached == 1 ? 'بلغ هدفه مرة' : 'بلغ هدفه $goalsReached مرات',
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.icon, required this.count, required this.says});

  final Widget Function(double size) icon;
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
            icon(16),
            const SizedBox(width: 3),
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

/// A crown: a filled body of three points, a ball on each, a base apart.
class RaceCrownPainter extends CustomPainter {
  RaceCrownPainter({required this.gold, required this.shade});

  final Color gold;

  /// Darkens the base a little, as in the drawing.
  final Color shade;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final fill = Paint()..color = gold;
    final body = Path()
      ..moveTo(w * 0.19, h * 0.72)
      ..lineTo(w * 0.10, h * 0.33)
      ..lineTo(w * 0.32, h * 0.52)
      ..lineTo(w * 0.50, h * 0.24)
      ..lineTo(w * 0.68, h * 0.52)
      ..lineTo(w * 0.90, h * 0.33)
      ..lineTo(w * 0.81, h * 0.72)
      ..close();
    canvas.drawPath(body, fill);
    for (final (x, y) in [(0.10, 0.28), (0.50, 0.18), (0.90, 0.28)]) {
      canvas.drawCircle(Offset(w * x, h * y), w * 0.085, fill);
    }
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.20, h * 0.78, w * 0.80, h * 0.90, Radius.circular(w * 0.04)),
      Paint()..color = Color.lerp(gold, shade, 0.14)!,
    );
  }

  @override
  bool shouldRepaint(RaceCrownPainter old) => old.gold != gold || old.shade != shade;
}

/// A target: two rings and a centre, struck by an arrow from the top corner.
class RaceTargetPainter extends CustomPainter {
  RaceTargetPainter({required this.rings, required this.arrow});

  final Color rings;
  final Color arrow;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final centre = Offset(w * 0.44, h * 0.56);
    final ring = Paint()
      ..color = rings
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.11;
    canvas.drawCircle(centre, w * 0.37, ring);
    canvas.drawCircle(centre, w * 0.19, ring..strokeWidth = w * 0.10);
    final green = Paint()..color = arrow;
    canvas.drawCircle(centre, w * 0.075, green);
    canvas.drawLine(
      centre,
      Offset(w * 0.84, h * 0.16),
      Paint()
        ..color = arrow
        ..strokeWidth = w * 0.075
        ..strokeCap = StrokeCap.round,
    );
    final fletch = Path()
      ..moveTo(w * 0.78, h * 0.12)
      ..lineTo(w * 0.86, h * 0.02)
      ..lineTo(w * 0.88, h * 0.12)
      ..lineTo(w * 0.98, h * 0.14)
      ..lineTo(w * 0.88, h * 0.22)
      ..close();
    canvas.drawPath(fletch, green);
  }

  @override
  bool shouldRepaint(RaceTargetPainter old) => old.rings != rings || old.arrow != arrow;
}
