import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../models/gold_price_series.dart';
import '../theme/app_semantic_colors.dart';

export '../models/gold_price_series.dart' show GoldChartSeries, SparklinePoint;

/// The home bar's price chart (the owner, 13 Nov 2026): the main karat's price
/// a gram by default, the ounce at a small toggle -- each line the server's.
///
/// What it kept: the opening's dashed line, the high's and the low's dots, the
/// last price's pulse, a crosshair with the point's time and price on hover or
/// a finger's drag, a tap opening the history. What it took from the manager's
/// card: a smooth line, it and the area under it green above the opening and
/// red below. What is new: a line of times under it, and the high and low --
/// the server's, over every row -- over it, where the hovered point says its
/// time and price instead, so nothing covers the line.
class GoldSparklineEnhanced extends StatefulWidget {
  final List<GoldChartSeries> series;
  final VoidCallback? onTap;
  final bool isArabic;

  /// The plot's height; the header and the times add about 36.
  final double height;

  const GoldSparklineEnhanced({
    super.key,
    required this.series,
    this.onTap,
    this.isArabic = true,
    this.height = 44,
  });

  @override
  State<GoldSparklineEnhanced> createState() => _GoldSparklineEnhancedState();
}

class _GoldSparklineEnhancedState extends State<GoldSparklineEnhanced> with SingleTickerProviderStateMixin {
  static final _price = NumberFormat('#,##0.00', 'en');

  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
  late final Animation<double> _pulseScale =
      Tween<double>(begin: 0.7, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  int _selected = 0;
  int _hovered = -1;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  GoldChartSeries? get _series =>
      widget.series.isEmpty ? null : widget.series[_selected.clamp(0, widget.series.length - 1)];

  void _hoverAt(double dx, double width) {
    final points = _series?.points ?? const [];
    if (points.length < 2) return;
    final i = _ChartGeometry.indexAt(dx, width, points.length);
    if (i != _hovered) setState(() => _hovered = i);
  }

  void _endHover() {
    if (_hovered != -1) setState(() => _hovered = -1);
  }

  @override
  Widget build(BuildContext context) {
    final c = _SparkPalette.of(context);
    final series = _series;
    final points = series?.points ?? const <SparklinePoint>[];
    final up = series == null || points.isEmpty || points.last.price >= (series.opening ?? points.first.price);
    final line = up ? c.up : c.down;
    final small = TextStyle(fontSize: 10.5, fontFamily: 'Cairo', color: c.muted);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('gold-chart'),
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 20, child: _header(c, series, small)),
              const SizedBox(height: 2),
              SizedBox(
                height: widget.height,
                child: points.length < 2
                    ? Center(child: Text('لا أسعار لآخر 24 ساعة', style: small))
                    : LayoutBuilder(
                        builder: (context, box) => MouseRegion(
                          onHover: (e) => _hoverAt(e.localPosition.dx, box.maxWidth),
                          onExit: (_) => _endHover(),
                          // A drag scrubs the line; a tap is left to the InkWell -- it opens the history.
                          child: GestureDetector(
                            onHorizontalDragStart: (d) => _hoverAt(d.localPosition.dx, box.maxWidth),
                            onHorizontalDragUpdate: (d) => _hoverAt(d.localPosition.dx, box.maxWidth),
                            onHorizontalDragEnd: (_) => _endHover(),
                            onHorizontalDragCancel: _endHover,
                            child: Semantics(
                              label: '${series!.label}: ${up ? 'صاعد' : 'نازل'} منذ الافتتاح',
                              child: AnimatedBuilder(
                                animation: _pulseScale,
                                builder: (context, _) => CustomPaint(
                                  size: Size(box.maxWidth, widget.height),
                                  painter: _SparklinePainter(
                                    points: points,
                                    opening: series.opening,
                                    hovered: _hovered,
                                    pulse: _pulseScale.value,
                                    line: line,
                                    up: c.up,
                                    down: c.down,
                                    openingLine: c.opening,
                                    ring: c.ring,
                                    crosshair: c.muted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 2),
              if (points.length >= 2) _times(points, small),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(_SparkPalette c, GoldChartSeries? series, TextStyle small) {
    final hovering = series != null && _hovered >= 0 && _hovered < series.points.length;
    final strong = small.copyWith(fontWeight: FontWeight.w700, color: c.ink);
    return Row(
      children: [
        if (widget.series.length > 1)
          _Toggle(
            labels: [for (final s in widget.series) s.label],
            selected: _selected,
            palette: c,
            onSelected: (i) => setState(() => (_selected = i, _hovered = -1)),
          )
        else if (series != null)
          Text(series.label, style: small.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: hovering
                  ? Container(
                      key: const Key('gold-chart-hovered'),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(color: c.tip, borderRadius: BorderRadius.circular(4)),
                      child: Text(
                        '${_hhmm(series.points[_hovered].time)}  '
                        '${_amount(series, series.points[_hovered].price)}',
                        textDirection: TextDirection.ltr,
                        style: strong,
                      ),
                    )
                  : (series?.high != null && series?.low != null)
                      ? Text.rich(
                          key: const Key('gold-chart-range'),
                          TextSpan(style: small, children: [
                            TextSpan(text: '● ', style: TextStyle(color: c.up)),
                            const TextSpan(text: 'أعلى '),
                            TextSpan(text: _amount(series!, series.high!), style: strong),
                            const TextSpan(text: '  ·  '),
                            TextSpan(text: '● ', style: TextStyle(color: c.down)),
                            const TextSpan(text: 'أدنى '),
                            TextSpan(text: _amount(series, series.low!), style: strong),
                          ]),
                        )
                      : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }

  /// «14:30»: a clock time needs no locale's data.
  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _amount(GoldChartSeries s, double v) =>
      s.unit == r'$' ? '\$${_price.format(v)}' : '${_price.format(v)} ${s.unit}';

  /// Five times along the line, left to right as the line runs.
  Widget _times(List<SparklinePoint> points, TextStyle small) {
    final n = points.length;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        key: const Key('gold-chart-times'),
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final f in const [0.0, 0.25, 0.5, 0.75, 1.0])
            Text(_hhmm(points[(f * (n - 1)).round()].time), style: small.copyWith(fontSize: 9.5)),
        ],
      ),
    );
  }
}

/// «عيار 21 | الأونصة»: the line the chart shows.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.labels, required this.selected, required this.palette, required this.onSelected});

  final List<String> labels;
  final int selected;
  final _SparkPalette palette;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, label) in labels.indexed)
            Semantics(
              button: true,
              selected: i == selected,
              child: InkWell(
                key: Key('gold-chart-series-$i'),
                borderRadius: BorderRadius.circular(5),
                onTap: () => onSelected(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  decoration: BoxDecoration(
                    color: i == selected ? palette.tip : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.5,
                      fontFamily: 'Cairo',
                      fontWeight: i == selected ? FontWeight.w800 : FontWeight.w600,
                      color: i == selected ? palette.ink : palette.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where a point falls, one rule for the painter and the hover.
class _ChartGeometry {
  static const padLeft = 6.0;
  static const padRight = 10.0;     // the last price's pulse

  static double x(int i, int n, double width) => padLeft + i / (n - 1) * (width - padLeft - padRight);

  static int indexAt(double dx, double width, int n) =>
      ((dx - padLeft) / (width - padLeft - padRight) * (n - 1)).round().clamp(0, n - 1);
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.opening,
    required this.hovered,
    required this.pulse,
    required this.line,
    required this.up,
    required this.down,
    required this.openingLine,
    required this.ring,
    required this.crosshair,
  });

  final List<SparklinePoint> points;
  final double? opening;
  final int hovered;
  final double pulse;
  final Color line;
  final Color up;
  final Color down;
  final Color openingLine;
  final Color ring;
  final Color crosshair;

  @override
  void paint(Canvas canvas, Size size) {
    final n = points.length;
    if (n < 2) return;
    var lo = 0, hi = 0;
    for (var i = 1; i < n; i++) {
      if (points[i].price < points[lo].price) lo = i;
      if (points[i].price > points[hi].price) hi = i;
    }
    // The opening is always in view: the line reads against it.
    var yMin = points[lo].price, yMax = points[hi].price;
    if (opening != null && opening! > 0) {
      if (opening! < yMin) yMin = opening!;
      if (opening! > yMax) yMax = opening!;
    }
    final pad = (yMax - yMin) == 0 ? 1.0 : (yMax - yMin) * 0.15;
    yMin -= pad;
    yMax += pad;
    const top = 4.0, bottom = 3.0;
    double y(double p) => top + (yMax - p) / (yMax - yMin) * (size.height - top - bottom);
    final pts = [for (var i = 0; i < n; i++) Offset(_ChartGeometry.x(i, n, size.width), y(points[i].price))];

    if (opening != null && opening! > 0) {
      _dashed(canvas, Offset(0, y(opening!)), Offset(size.width, y(opening!)),
          Paint()..color = openingLine..strokeWidth = 1);
    }

    // A smooth line through every point (Catmull-Rom as cubic Béziers).
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < n - 1; i++) {
      final p0 = pts[i == 0 ? 0 : i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2 < n ? i + 2 : n - 1];
      path.cubicTo(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6,
          p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6, p2.dx, p2.dy);
    }
    final area = Path.from(path)
      ..lineTo(pts.last.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = line.withValues(alpha: 0.10));
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    if (hi != n - 1) canvas.drawCircle(pts[hi], 2.5, Paint()..color = up);
    if (lo != n - 1) canvas.drawCircle(pts[lo], 2.5, Paint()..color = down);

    if (hovered >= 0 && hovered < n) {
      final h = pts[hovered];
      _dashed(canvas, Offset(h.dx, 0), Offset(h.dx, size.height), Paint()..color = crosshair..strokeWidth = 1,
          dash: 2, gap: 2);
      canvas.drawCircle(h, 5.5, Paint()..color = ring);
      canvas.drawCircle(h, 4, Paint()..color = line);
    }

    final last = pts.last;
    canvas.drawCircle(last, 7 * pulse, Paint()..color = line.withValues(alpha: 0.25));
    canvas.drawCircle(last, 5, Paint()..color = ring);
    canvas.drawCircle(last, 3.5, Paint()..color = line);
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint, {double dash = 3, double gap = 3}) {
    final length = (b - a).distance;
    if (length == 0) return;
    final dir = (b - a) / length;
    for (var s = 0.0; s < length; s += dash + gap) {
      canvas.drawLine(a + dir * s, a + dir * (s + dash < length ? s + dash : length), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.pulse != pulse ||
      old.hovered != hovered ||
      old.points != points ||
      old.opening != opening ||
      old.line != line ||
      old.ring != ring;
}

/// The chart's colours, the theme's: green above the opening and red below
/// (the manager's card), the opening's line in the gold.
@immutable
class _SparkPalette {
  _SparkPalette.of(BuildContext context)
      : up = AppSemanticColors.of(context).ready.fg,
        down = AppSemanticColors.of(context).blocked.fg,
        opening = Theme.of(context).colorScheme.primary.withValues(alpha: 0.50),
        tip = Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
        ink = Theme.of(context).colorScheme.onSurface,
        muted = Theme.of(context).colorScheme.onSurfaceVariant,
        border = Theme.of(context).colorScheme.outlineVariant,
        ring = Theme.of(context).colorScheme.surfaceContainerLowest;

  final Color up;
  final Color down;
  final Color opening;
  final Color tip;
  final Color ink;
  final Color muted;
  final Color border;
  final Color ring;
}
