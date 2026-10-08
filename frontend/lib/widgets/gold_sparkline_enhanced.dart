import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../theme/app_semantic_colors.dart';

/// نقطة في الـ sparkline
class SparklinePoint {
  final DateTime time;
  final double price;
  const SparklinePoint({required this.time, required this.price});
}

class GoldSparklineEnhanced extends StatefulWidget {
  /// نقاط البيانات (24 ساعة الماضية مثلاً)
  final List<SparklinePoint> points;

  /// سعر الفتح (لرسم خط الأساس)
  final double? openingPrice;

  /// عملة العرض
  final String currencySymbol;

  /// عند الضغط
  final VoidCallback? onTap;

  /// لغة العرض
  final bool isArabic;

  /// عرض المؤشر
  final double? width;

  /// ارتفاع منطقة الرسم
  final double height;

  const GoldSparklineEnhanced({
    super.key,
    required this.points,
    this.openingPrice,
    this.currencySymbol = 'ر.س',
    this.onTap,
    this.isArabic = true,
    this.width,
    this.height = 60,
  });

  @override
  State<GoldSparklineEnhanced> createState() => _GoldSparklineEnhancedState();
}

class _GoldSparklineEnhancedState extends State<GoldSparklineEnhanced>
    with SingleTickerProviderStateMixin {
  /// ألوان المنحنى من الثيم (ثيم-٠).
  _SparkPalette get _c => _SparkPalette.of(context);

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  int _hoveredIndex = -1;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  ({double min, double max, int minIdx, int maxIdx}) _getMinMax() {
    if (widget.points.isEmpty) {
      return (min: 0, max: 0, minIdx: -1, maxIdx: -1);
    }
    var min = widget.points.first.price;
    var max = widget.points.first.price;
    var minIdx = 0;
    var maxIdx = 0;
    for (var i = 1; i < widget.points.length; i++) {
      final p = widget.points[i].price;
      if (p < min) {
        min = p;
        minIdx = i;
      }
      if (p > max) {
        max = p;
        maxIdx = i;
      }
    }
    return (min: min, max: max, minIdx: minIdx, maxIdx: maxIdx);
  }

  double get _percentChange {
    if (widget.points.length < 2) return 0;
    final first = widget.openingPrice ?? widget.points.first.price;
    final last = widget.points.last.price;
    if (first == 0) return 0;
    return ((last - first) / first) * 100;
  }

  String _formatPrice(double price) =>
      NumberFormat('#,##0.00', 'en').format(price);

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return _buildEmptyState(context);
    }

    final isAr = widget.isArabic;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stats = _getMinMax();
    final change = _percentChange;
    final isUp = change >= 0;
    final firstPrice = widget.openingPrice ?? widget.points.first.price;
    final lastPrice = widget.points.last.price;

    return SizedBox(
      width: widget.width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildContextRow(
                  isAr, isDark, change, isUp,
                  firstPrice: firstPrice,
                  lastPrice: lastPrice,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: widget.height,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return MouseRegion(
                        onHover: (event) =>
                            _handleHover(event.localPosition, constraints),
                        onExit: (_) => setState(() => _hoveredIndex = -1),
                        child: GestureDetector(
                          onTapDown: (details) =>
                              _handleHover(details.localPosition, constraints),
                          onTapUp: (_) {
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) setState(() => _hoveredIndex = -1);
                            });
                          },
                          child: AnimatedBuilder(
                            animation: _pulseAnimation,
                            builder: (context, _) {
                              return CustomPaint(
                                size: Size(constraints.maxWidth, widget.height),
                                painter: _SparklineEnhancedPainter(
                                  points: widget.points,
                                  openingPrice: widget.openingPrice,
                                  minIdx: stats.minIdx,
                                  maxIdx: stats.maxIdx,
                                  pulseScale: _pulseAnimation.value,
                                  hoveredIndex: _hoveredIndex,
                                  colors: _c,
                                  isUp: isUp,
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_hoveredIndex >= 0 && _hoveredIndex < widget.points.length)
                  _buildTooltip(widget.points[_hoveredIndex], isAr, isDark)
                else
                  _buildBottomLabels(isAr, isDark, stats),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContextRow(
    bool isAr,
    bool isDark,
    double change,
    bool isUp, {
    required double firstPrice,
    required double lastPrice,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isAr ? 'آخر 24س' : '24h',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Cairo',
                  color: (isDark ? _c.muted : _c.line),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                isAr ? 'تحديث الآن' : 'Live',
                style: TextStyle(
                  fontSize: 8,
                  fontFamily: 'Cairo',
                  color: _c.muted,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          fit: FlexFit.loose,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: (isUp ? _c.up : _c.down)
                      .withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '${isUp ? '▲' : '▼'} ${change.abs().toStringAsFixed(2)}%',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'Cairo',
                    color: isUp ? _c.up : _c.down,
                  ),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                '${_formatPrice(firstPrice)} → ${_formatPrice(lastPrice)}',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 8,
                  fontFamily: 'Cairo',
                  color: _c.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTooltip(SparklinePoint point, bool isAr, bool isDark) {
    final timeStr = DateFormat('HH:mm', 'en').format(point.time);
    final diff = DateTime.now().difference(point.time);
    final ago = diff.inHours < 1
        ? (isAr ? 'منذ ${diff.inMinutes}د' : '${diff.inMinutes}m ago')
        : (isAr ? 'منذ ${diff.inHours}س' : '${diff.inHours}h ago');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: _c.gold.withValues(alpha: isDark ? 0.15 : 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: _c.gold.withValues(alpha: 0.30),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '\$${_formatPrice(point.price)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              fontFamily: 'Cairo',
              color: _c.line,
            ),
          ),
          Text(
            '$timeStr · $ago',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 8,
              fontFamily: 'Cairo',
              color: _c.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomLabels(
    bool isAr,
    bool isDark,
    ({double min, double max, int minIdx, int maxIdx}) stats,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: _c.down,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                _formatPrice(stats.min),
                style: TextStyle(
                  fontSize: 9,
                  fontFamily: 'Cairo',
                  color: _c.muted,
                ),
              ),
            ],
          ),
          if (widget.onTap != null)
            Flexible(
              fit: FlexFit.loose,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  isAr ? 'اضغط للتفاصيل' : 'Tap for details',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 8,
                    fontFamily: 'Cairo',
                    fontStyle: FontStyle.italic,
                    color: _c.muted,
                  ),
                ),
              ),
            ),
          Row(
            children: [
              Text(
                _formatPrice(stats.max),
                style: TextStyle(
                  fontSize: 9,
                  fontFamily: 'Cairo',
                  color: _c.muted,
                ),
              ),
              const SizedBox(width: 3),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: _c.up,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height + 30,
      child: Center(
        child: Text(
          widget.isArabic
              ? 'لا توجد بيانات لآخر 24 ساعة'
              : 'No 24h data available',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'Cairo',
            color: _c.muted,
          ),
        ),
      ),
    );
  }

  void _handleHover(Offset position, BoxConstraints constraints) {
    if (widget.points.isEmpty) return;
    final stepX =
        constraints.maxWidth / (widget.points.length - 1).clamp(1, 9999);
    final nearestIdx =
        (position.dx / stepX).round().clamp(0, widget.points.length - 1);
    if (nearestIdx != _hoveredIndex) {
      setState(() => _hoveredIndex = nearestIdx);
    }
  }
}

// ════════════════════════════════════════════════════════════════
// CustomPainter
// ════════════════════════════════════════════════════════════════
class _SparklineEnhancedPainter extends CustomPainter {
  final List<SparklinePoint> points;
  final double? openingPrice;
  final int minIdx;
  final int maxIdx;
  final double pulseScale;
  final int hoveredIndex;
  final _SparkPalette colors;
  final bool isUp;

  _SparklineEnhancedPainter({
    required this.points,
    required this.openingPrice,
    required this.minIdx,
    required this.maxIdx,
    required this.pulseScale,
    required this.hoveredIndex,
    required this.colors,
    required this.isUp,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    // يمنع تجاوز النقطة النابضة حدود الـ canvas
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);

    var minPrice = points.first.price;
    var maxPrice = points.first.price;
    for (final p in points) {
      if (p.price < minPrice) minPrice = p.price;
      if (p.price > maxPrice) maxPrice = p.price;
    }
    final range = (maxPrice - minPrice).abs();
    final pad = range == 0 ? 1.0 : range * 0.15;
    final yMin = minPrice - pad;
    final yMax = maxPrice + pad;
    final yRange = (yMax - yMin).clamp(0.0001, double.infinity);

    // inset أفقي لحماية النقاط من الحواف (نصف قطر أكبر نقطة = 3.5 + stroke 1.5 = 5)
    const hPad = 6.0;

    double toY(double price) =>
        size.height - ((price - yMin) / yRange * size.height);

    double toX(int idx) =>
        hPad + (idx / (points.length - 1)) * (size.width - 2 * hPad);

    // 1. خط الأساس المتقطّع
    if (openingPrice != null &&
        openingPrice! >= yMin &&
        openingPrice! <= yMax) {
      final y = toY(openingPrice!);
      _drawDashedLine(
        canvas,
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = colors.gold.withValues(alpha: 0.30)
          ..strokeWidth = 0.7
          ..style = PaintingStyle.stroke,
      );
    }

    // 2. المسار + gradient
    final linePath = Path();
    final fillPath = Path();
    for (var i = 0; i < points.length; i++) {
      final x = toX(i);
      final y = toY(points[i].price);
      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colors.gold.withValues(alpha: 0.40),
            colors.gold.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      linePath,
      Paint()
        ..color = colors.line
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // 3. نقطة min (حمراء)
    if (minIdx >= 0 && minIdx < points.length && minIdx != points.length - 1) {
      _drawDot(canvas, Offset(toX(minIdx), toY(points[minIdx].price)),
          colors.down, radius: 2.5);
    }

    // 4. نقطة max (خضراء)
    if (maxIdx >= 0 && maxIdx < points.length && maxIdx != points.length - 1) {
      _drawDot(canvas, Offset(toX(maxIdx), toY(points[maxIdx].price)),
          colors.up, radius: 2.5);
    }

    // 5. crosshair عند hover
    if (hoveredIndex >= 0 && hoveredIndex < points.length) {
      final hx = toX(hoveredIndex);
      final hy = toY(points[hoveredIndex].price);
      _drawDashedLine(
        canvas,
        Offset(hx, 0),
        Offset(hx, size.height),
        Paint()
          ..color = colors.line.withValues(alpha: 0.50)
          ..strokeWidth = 0.8,
      );
      _drawDot(canvas, Offset(hx, hy), colors.line,
          radius: 4, strokeWidth: 1.5, strokeColor: colors.ring);
    }

    // 6. النقطة النابضة على آخر سعر
    final lastX = toX(points.length - 1);
    final lastY = toY(points.last.price);

    canvas.drawCircle(
      Offset(lastX, lastY),
      7 * pulseScale,
      Paint()
        ..color = colors.gold.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill,
    );
    _drawDot(canvas, Offset(lastX, lastY), colors.gold,
        radius: 3.5, strokeWidth: 1.5, strokeColor: colors.ring);
  }

  void _drawDot(
    Canvas canvas,
    Offset center,
    Color color, {
    required double radius,
    double strokeWidth = 0,
    Color? strokeColor,
  }) {
    if (strokeWidth > 0 && strokeColor != null) {
      canvas.drawCircle(
        center,
        radius + strokeWidth,
        Paint()
          ..color = strokeColor
          ..style = PaintingStyle.fill,
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double dashLength = 3,
    double gapLength = 3,
  }) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = (end - start).distance;
    if (length == 0) return;

    final stepSize = dashLength + gapLength;
    final steps = (length / stepSize).floor();
    for (var i = 0; i <= steps; i++) {
      final s = Offset(
          start.dx + (dx / length) * stepSize * i,
          start.dy + (dy / length) * stepSize * i);
      final e = Offset(
          s.dx + (dx / length) * dashLength,
          s.dy + (dy / length) * dashLength);
      canvas.drawLine(s, e, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklineEnhancedPainter old) =>
      old.pulseScale != pulseScale ||
      old.colors != colors ||
      old.hoveredIndex != hoveredIndex ||
      old.points.length != points.length;
}

/// ألوان المنحنى: الذهب للمسار، والجاهز/المحظور للأعلى/الأدنى.
@immutable
class _SparkPalette {
  _SparkPalette.of(BuildContext context)
    : gold = Theme.of(context).colorScheme.primary,
      line = AppSemanticColors.of(context).gold.fg,
      up = AppSemanticColors.of(context).ready.fg,
      down = AppSemanticColors.of(context).blocked.fg,
      muted = Theme.of(context).colorScheme.onSurfaceVariant,
      ring = Theme.of(context).colorScheme.surfaceContainerLowest;

  final Color gold;
  final Color line;
  final Color up;
  final Color down;
  final Color muted;
  final Color ring;

  @override
  bool operator ==(Object other) =>
      other is _SparkPalette &&
      other.gold == gold &&
      other.line == line &&
      other.up == up &&
      other.down == down &&
      other.muted == muted &&
      other.ring == ring;

  @override
  int get hashCode => Object.hash(gold, line, up, down, muted, ring);
}
