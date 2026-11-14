import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../theme/app_tokens.dart';
import '../../../utils/currency_utils.dart' as cu;

/// The manager's dashboard's shared pieces (DASH-10, the owner 30 Oct 2026:
/// «تصميمات احترافية ومبتكرة وليس فقط بطاقات مصمتة»). One look for every
/// section: a quiet panel, a section's heading, a grid that is three columns
/// wide and one on a phone, its shape while it loads, and the amounts said the
/// screen's one way.

/// How an amount and a weight are said -- the screen's formats, passed once.
class DashboardMoney {
  const DashboardMoney({
    required this.format,
    required this.symbol,
    required this.isNewSar,
    required this.weight,
  });

  final NumberFormat format;
  final String symbol;
  final bool isNewSar;
  final NumberFormat weight;

  String cash(num v) => '${format.format(v)} $symbol';

  String grams(num v, {bool isArabic = true}) => '${weight.format(v)} ${isArabic ? 'جم' : 'g'}';

  Widget text(num v, {TextStyle? style}) => cu.SarAwareText(cash(v), isNewSar: isNewSar, style: style);
}

double dashboardNum(dynamic v) => v is num ? v.toDouble() : 0.0;

/// A drawn mark -- a bar, a segment, a dot -- in a tone's colour. The light
/// theme's tones are text colours, strong enough to read at 4.5:1; a whole bar
/// of one is loud (the owner, 30 Oct 2026: «اللون الأحمر في الوضع الفاتح قوي
/// جداً»), so a mark wears it softened there. The dark theme's are soft already.
Color dashboardMark(BuildContext context, Color tone) =>
    Theme.of(context).brightness == Brightness.light ? tone.withValues(alpha: 0.55) : tone;

/// Figures read in columns: the same width for every digit.
TextStyle? dashboardFigure(TextStyle? base, {FontWeight weight = FontWeight.w700, Color? color}) =>
    base?.copyWith(fontWeight: weight, color: color, fontFeatures: const [FontFeature.tabularFigures()]);

/// A section's heading: an accent, its name, what it covers, and what acts on it.
class DashboardSection extends StatelessWidget {
  const DashboardSection({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: AppSpace.xs,
          height: 22,
          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(AppRadius.pill)),
        ),
        const SizedBox(width: AppSpace.sm + 2),
        Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        if (subtitle != null) ...[
          const SizedBox(width: AppSpace.sm + 2),
          Flexible(
            child: Text(subtitle!,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// A quiet panel: the surface a step above the page, a hairline, no fill of
/// colour -- the colour is the data's. A heading with its icon and its figure.
class DashboardPanel extends StatelessWidget {
  const DashboardPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.figure,
    this.accent,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? figure;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = accent ?? scheme.primary;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                    child: Icon(icon, size: 17, color: tint),
                  ),
                  const SizedBox(width: AppSpace.sm + 2),
                  Expanded(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  ?figure,
                ],
              ),
              const SizedBox(height: AppSpace.md + 2),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A panel's shape while its reading is on the way -- the theme's grey, as
/// AppLoadingView draws a page (ADR-057), not a spinner.
class DashboardPanelSkeleton extends StatelessWidget {
  const DashboardPanelSkeleton({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHighest.withValues(alpha: 0.7);
    Widget bar(double width, double height) => FractionallySizedBox(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: width,
          child: Container(
            height: height,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(AppRadius.chip)),
          ),
        );
    return Semantics(
      label: 'جارٍ التحميل',
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            bar(0.4, 18),
            for (var i = 0; i < lines; i++) ...[
              const SizedBox(height: AppSpace.md),
              bar(i.isEven ? 0.9 : 0.65, 12),
            ],
          ],
        ),
      ),
    );
  }
}

/// Up to three columns on a wide screen, two on a middle one, one on a phone;
/// the last row's tiles share its width.
class DashboardGrid extends StatelessWidget {
  const DashboardGrid({super.key, required this.children, this.minTileWidth = 340});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    const spacing = AppSpace.md;
    return LayoutBuilder(builder: (context, constraints) {
      final columns = ((constraints.maxWidth + spacing) ~/ (minTileWidth + spacing)).clamp(1, 3);
      final rows = <Widget>[];
      for (var i = 0; i < children.length; i += columns) {
        final row = children.sublist(i, (i + columns).clamp(0, children.length));
        rows.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (j, tile) in row.indexed) ...[
              if (j > 0) const SizedBox(width: spacing),
              Expanded(child: tile),
            ],
          ],
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: spacing),
            row,
          ],
        ],
      );
    });
  }
}

/// One line of a [DashboardAmountTable]: its name, its amount, and its weight
/// when it has one; [decoration] its band.
class DashboardAmountRow {
  const DashboardAmountRow({required this.label, required this.amount, this.weight, this.decoration});

  final Widget label;
  final Widget amount;
  final String? weight;
  final Decoration? decoration;
}

/// Amounts with their weights beside them, set apart and in columns (the
/// owner, 30-31 Oct 2026: «فاصل بين الوزن والمبلغ ... الأوزان بعدت عن المبالغ
/// ... المسافة بين كلمة "جرام" وأكبر مبلغ إلى الفاصل بنفس المسافة»). A table:
/// the weights' column as wide as its widest chip, the amounts' as wide as the
/// widest amount, so each hairline stands in one column and the widest amount
/// sits as far from it as the word «جم» does -- the chip's own padding counted.
class DashboardAmountTable extends StatelessWidget {
  const DashboardAmountTable({
    super.key,
    required this.rows,
    this.rowPadding = const EdgeInsets.symmetric(vertical: 6),
    this.edge = 0,
  });

  final List<DashboardAmountRow> rows;
  final EdgeInsets rowPadding;

  /// Inside a band, the room at its two ends.
  final double edge;

  /// Between the chip's edge and the hairline; the chip's own padding makes
  /// the word's distance [_chipPadding] + this, and the amount's is the same.
  static const _gap = AppSpace.sm;
  static const _chipPadding = AppSpace.sm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final anyWeight = rows.any((r) => r.weight != null);
    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: {
        0: const FlexColumnWidth(),
        1: const IntrinsicColumnWidth(),
        2: FixedColumnWidth(anyWeight ? _gap + 1 + _chipPadding + _gap : 0),
        3: const IntrinsicColumnWidth(),
      },
      children: [
        for (final r in rows)
          TableRow(
            decoration: r.decoration,
            children: [
              Padding(
                padding: rowPadding.add(EdgeInsetsDirectional.only(start: edge)),
                child: Align(alignment: AlignmentDirectional.centerStart, child: r.label),
              ),
              r.weight == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: rowPadding.add(const EdgeInsetsDirectional.only(start: AppSpace.sm)),
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: _chipPadding, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(AppRadius.chip),
                          ),
                          child: Text(
                            r.weight!,
                            style: dashboardFigure(theme.textTheme.bodySmall,
                                weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
              r.weight == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsetsDirectional.only(start: _gap, end: _chipPadding + _gap),
                      child: Center(
                        child: Container(
                          key: const Key('weight-amount-divider'),
                          width: 1,
                          height: 16,
                          color: scheme.outlineVariant,
                        ),
                      ),
                    ),
              Padding(
                padding: rowPadding.add(EdgeInsetsDirectional.only(end: edge)),
                child: Align(alignment: AlignmentDirectional.centerEnd, child: r.amount),
              ),
            ],
          ),
      ],
    );
  }
}


/// One karat in [KaratDonut]: its number, its grams, its colour.
class KaratShare {
  const KaratShare(this.karat, this.grams, this.color);

  final int karat;
  final double grams;
  final Color color;
}

/// The karats held, each slice at its true size (the owner, 14 Nov 2026:
/// «ترسم بحجمها ويكون هناك خط يوشر على منطقتها»): a slice wide enough says
/// its karat inside; a narrower one has a line from its middle out of the
/// ring to its karat, in its colour. Each says its karat «24K» (the owner,
/// 14 Nov 2026: «اقصد رمز مثل 24K»). A karat with nothing held has no slice.
class KaratDonut extends StatelessWidget {
  const KaratDonut({super.key, required this.shares, required this.inside, required this.outside});

  final List<KaratShare> shares;

  /// The style of a karat said inside its slice, and of one said at a line's end.
  final TextStyle inside;
  final TextStyle outside;

  /// A slice this share of the whole or more says its karat inside.
  static const insideFrom = 0.08;
  static const centre = 24.0;
  static const ring = 34.0;
  static const size = Size(220, 150);

  @override
  Widget build(BuildContext context) {
    final held = [for (final s in shares) if (s.grams > 0) s];
    final total = held.fold<double>(0, (sum, s) => sum + s.grams);
    final side = (centre + ring) * 2;
    return SizedBox.fromSize(
      size: size,
      child: Stack(children: [
        Positioned(
          left: (size.width - side) / 2,
          top: (size.height - side) / 2,
          width: side,
          height: side,
          child: PieChart(PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: centre,
            sections: [
              for (final s in held)
                PieChartSectionData(
                  value: s.grams,
                  color: s.color,
                  radius: ring,
                  title: '${s.karat}K',
                  showTitle: s.grams / total >= insideFrom,
                  titlePositionPercentageOffset: 0.55,
                  titleStyle: inside,
                ),
            ],
          )),
        ),
        Positioned.fill(
          child: CustomPaint(
            key: const Key('karat-mix-leaders'),
            painter: KaratLeaderPainter(
              leaders: [
                for (final (i, s) in held.indexed)
                  if (s.grams / total < insideFrom)
                    (s, _middle(held, total, i)),
              ],
              style: outside,
              radius: centre + ring,
            ),
          ),
        ),
      ]),
    );
  }

  /// A slice's middle, in radians: the chart starts at the right and turns
  /// clockwise, each slice its share of the turn.
  static double _middle(List<KaratShare> held, double total, int index) {
    final before = held.take(index).fold<double>(0, (sum, s) => sum + s.grams);
    return (before + held[index].grams / 2) / total * 2 * math.pi;
  }
}

/// The lines out of [KaratDonut]'s narrow slices, each to its karat; two
/// whose ends would touch are pulled apart.
class KaratLeaderPainter extends CustomPainter {
  KaratLeaderPainter({required this.leaders, required this.style, required this.radius});

  /// Each narrow slice, with its middle in radians.
  final List<(KaratShare, double)> leaders;
  final TextStyle style;
  final double radius;

  static const out = 16.0;
  static const run = 14.0;
  static const apart = 16.0;

  List<int> get karats => [for (final (s, _) in leaders) s.karat];

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final placed = <(KaratShare, Offset, Offset)>[];
    for (final (s, angle) in leaders) {
      final dir = Offset(math.cos(angle), math.sin(angle));
      placed.add((s, centre + dir * radius, centre + dir * (radius + out)));
    }
    for (final right in [true, false]) {
      final onSide = [for (final p in placed) if ((p.$3.dx >= centre.dx) == right) p]
        ..sort((a, b) => a.$3.dy.compareTo(b.$3.dy));
      for (var i = 1; i < onSide.length; i++) {
        final (s, from, elbow) = onSide[i];
        final lowest = onSide[i - 1].$3.dy + apart;
        if (elbow.dy < lowest) {
          final moved = (s, from, Offset(elbow.dx, lowest));
          onSide[i] = moved;
          placed[placed.indexWhere((p) => p.$1 == s)] = moved;
        }
      }
    }
    for (final (s, from, elbow) in placed) {
      final right = elbow.dx >= centre.dx;
      final end = elbow + Offset(right ? run : -run, 0);
      final line = Paint()
        ..color = s.color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawPath(Path()..moveTo(from.dx, from.dy)..lineTo(elbow.dx, elbow.dy)..lineTo(end.dx, end.dy), line);
      canvas.drawCircle(from, 2, Paint()..color = s.color);
      final text = TextPainter(
        text: TextSpan(text: '${s.karat}K', style: style.copyWith(color: s.color)),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(right ? end.dx + 3 : end.dx - 3 - text.width, end.dy - text.height / 2));
    }
  }

  @override
  bool shouldRepaint(KaratLeaderPainter old) =>
      old.leaders != leaders || old.style != style || old.radius != radius;
}
