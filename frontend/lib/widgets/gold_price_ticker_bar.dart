import 'dart:async';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/gold_prices.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' as cu;

/// Drives the ticker scroll via [FlowDelegate.paintChildren] only.
/// Because [repaint] is the animation, each animation tick triggers a
/// paint-only pass — no widget rebuild, no layout pass.
class _TickerFlowDelegate extends FlowDelegate {
  final Animation<double> animation;
  final double cycleWidth;
  final int cycles;
  final bool isArabic;
  final double viewportWidth;

  _TickerFlowDelegate({
    required this.animation,
    required this.cycleWidth,
    required this.cycles,
    required this.isArabic,
    required this.viewportWidth,
  }) : super(repaint: animation);

  @override
  Size getSize(BoxConstraints constraints) =>
      Size(constraints.maxWidth, constraints.maxHeight);

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) {
    // Let every child (content tile and measure child) use its natural width.
    // Constraining to a fixed cycleWidth causes overflow when the tile content
    // is wider than the fallback estimate.
    return BoxConstraints(maxHeight: constraints.maxHeight);
  }

  @override
  void paintChildren(FlowPaintingContext context) {
    // Use the actual rendered width of the first tile so that spacing is
    // always exact regardless of the cycleWidth estimate.
    final tileW = (cycles > 0 ? context.getChildSize(0)?.width : null) ??
        cycleWidth;
    if (tileW <= 0) return;
    final shift = animation.value * tileW;
    final baseX = isArabic ? (-tileW + shift) : (viewportWidth - shift);
    for (int j = 0; j < cycles; j++) {
      final dx = baseX + ((j - 2) * tileW);
      final childH = context.getChildSize(j)?.height ?? 0;
      final dy = (context.size.height - childH) / 2;
      context.paintChild(
        j,
        transform: Matrix4.translationValues(dx, dy, 0),
      );
    }
    // Child at index [cycles] is the hidden measure widget — never painted.
  }

  @override
  bool shouldRepaint(_TickerFlowDelegate old) =>
      old.cycleWidth != cycleWidth ||
      old.cycles != cycles ||
      old.isArabic != isArabic ||
      old.viewportWidth != viewportWidth;
}

class GoldPriceTickerBar extends StatefulWidget {
  final bool isArabic;

  /// Optional prices provided by the parent -- each karat's, the server's
  /// (OFFICE-PRICE-1). When set, the ticker renders from them and updates
  /// immediately when they change (useful after a manual refresh).
  final GoldPrices? prices;

  /// Optional opening prices for today, each karat's, the server's: the
  /// change shown is against them.
  final GoldPrices? openingPrices;

  /// Refresh interval. If null, no auto refresh.
  final Duration? refreshInterval;

  /// Currency symbol shown alongside prices.
  final String currencySymbol;

  /// True when the new 2020 SAR graphic symbol is selected.
  final bool isNewSar;

  const GoldPriceTickerBar({
    super.key,
    required this.isArabic,
    this.prices,
    this.openingPrices,
    this.refreshInterval,
    this.currencySymbol = 'ر.س',
    this.isNewSar = false,
  });

  @override
  State<GoldPriceTickerBar> createState() => _GoldPriceTickerBarState();
}

class _GoldPriceTickerBarState extends State<GoldPriceTickerBar>
    with SingleTickerProviderStateMixin {
  final ApiService _api = ApiService();

  Timer? _timer;
  double? _ouncePriceUsd;
  String? _loadError;

  late final AnimationController _controller;

  final Map<int, double> _lastPrices = {};
  final Map<int, double> _changeAbs = {};
  final Map<int, double> _changePct = {};
  final Map<int, double> _openingPrices = {};

  final GlobalKey _measureKey = GlobalKey();
  double _measuredWidth = 0.0;

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _measureKey.currentContext?.findRenderObject();
      final box = renderObject is RenderBox ? renderObject : null;
      if (box == null) return;
      final w = box.size.width;
      if (w <= 0) return;
      if ((w - _measuredWidth).abs() < 0.5) return;
      setState(() => _measuredWidth = w);
    });
  }

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();

    if (widget.openingPrices?.known ?? false) {
      _applyOpening(widget.openingPrices!);
    }

    if (widget.prices?.known ?? false) {
      _applyPrices(widget.prices!, resetError: true);
    } else {
      _load();
    }

    final interval = widget.refreshInterval;
    if (interval != null) {
      _timer = Timer.periodic(interval, (_) => _load());
    }
  }

  @override
  void didUpdateWidget(covariant GoldPriceTickerBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    final nextOpening = widget.openingPrices;
    if ((nextOpening?.known ?? false) && !identical(nextOpening, oldWidget.openingPrices)) {
      _applyOpening(nextOpening!);
    }

    final next = widget.prices;
    // If parent drives the value, prefer it and update immediately.
    if ((next?.known ?? false) && !identical(next, oldWidget.prices)) {
      _applyPrices(next!, resetError: true);
    }

    if (oldWidget.refreshInterval != widget.refreshInterval) {
      _timer?.cancel();
      _timer = null;
      final interval = widget.refreshInterval;
      if (interval != null) {
        _timer = Timer.periodic(interval, (_) => _load());
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _controller.dispose();
    super.dispose();
  }

  // الألوان من الثيم (ثيم-٠)؛ كل عيار بلونه، وكل وضع بنسخته.
  Color _karatAccentColor(int karat, {required bool isDark}) =>
      AppSemanticColors.of(context).karat(karat).fg;

  Color _trendColor(double delta, {required bool isDark}) {
    final tones = AppSemanticColors.of(context);
    if (delta > 0) return tones.ready.fg;
    if (delta < 0) return tones.blocked.fg;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  static const _karats = [24, 22, 21, 18];

  void _applyOpening(GoldPrices opening) {
    setState(() {
      _openingPrices
        ..clear()
        ..addAll({for (final k in _karats) k: opening.of(k)});
    });
  }

  void _applyPrices(GoldPrices prices, {required bool resetError}) {
    _ouncePriceUsd = prices.ounceUsd > 0 ? prices.ounceUsd : _ouncePriceUsd;
    final current = <int, double>{for (final k in _karats) k: prices.of(k)};

    // The change is against today's opening; without one, the previous update.
    final Map<int, double>? prevSnapshot = _openingPrices.isNotEmpty
        ? Map<int, double>.from(_openingPrices)
        : (_lastPrices.isNotEmpty ? Map<int, double>.from(_lastPrices) : null);

    final nextAbs = <int, double>{};
    final nextPct = <int, double>{};
    for (final entry in current.entries) {
      final k = entry.key;
      final v = entry.value;
      final p = prevSnapshot?[k];
      if (p != null && p.abs() > 1e-9) {
        final d = v - p;
        nextAbs[k] = d;
        nextPct[k] = (d / p) * 100.0;
      }
    }

    setState(() {
      _lastPrices
        ..clear()
        ..addAll(current);
      _changeAbs
        ..clear()
        ..addAll(nextAbs);
      _changePct
        ..clear()
        ..addAll(nextPct);
      if (resetError) _loadError = null;
      if (_controller.isAnimating == false) {
        _controller.repeat();
      }
    });

    // Re-measure content width so cycleWidth is correct after data loads.
    // This is required when the parent provides the prices directly
    // (bypassing _load()), so _scheduleMeasure() would never be triggered
    // otherwise.
    _scheduleMeasure();
  }

  Future<void> _load() async {
    try {
      // If the parent is driving the value, avoid polling overrides.
      if (widget.prices?.known ?? false) {
        return;
      }
      final res = await _api.getGoldPricePublic();

      final opening = GoldPrices.openingFromResponse(res);
      if (opening.known) {
        _applyOpening(opening);
      }

      final prices = GoldPrices.fromResponse(res);
      if (!mounted) return;
      if (!prices.known) {
        setState(() {
          _ouncePriceUsd = null;
          _loadError = widget.isArabic
              ? 'لا يوجد سعر ذهب متاح حالياً'
              : 'No gold price available right now';
          _lastPrices.clear();
          _changeAbs.clear();
          _changePct.clear();
        });
        return;
      }

      _applyPrices(prices, resetError: true);
      _scheduleMeasure();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // Keep last known prices if available; otherwise show an error message.
        _loadError ??= widget.isArabic
            ? 'تعذر تحميل سعر الذهب'
            : 'Failed to load gold price';
      });
    }
  }

  Widget _chip({
    required int karat,
    required TextStyle baseStyle,
    required bool isDark,
    required bool isArabic,
  }) {
    final accent = _karatAccentColor(karat, isDark: isDark);
    final label = isArabic ? 'عيار $karat' : 'K$karat';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 0.8),
      ),
      child: Text(
        label,
        style: baseStyle.copyWith(color: accent, fontWeight: FontWeight.w900),
        maxLines: 1,
      ),
    );
  }

  Widget _segment({
    required int karat,
    required TextStyle baseStyle,
    required bool isDark,
    required bool isArabic,
  }) {
    final price = _lastPrices[karat] ?? 0.0;
    final abs = _changeAbs[karat];
    final pct = _changePct[karat];
    final changeColor = _trendColor(abs ?? 0.0, isDark: isDark);

    String fmt(double v) => v.toStringAsFixed(2);
    String fmtPct(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';
    String fmtDelta(double v) {
      final sign = v >= 0 ? '+' : '';
      return '$sign${fmt(v)}';
    }

    final children = <Widget>[
      _chip(
        karat: karat,
        baseStyle: baseStyle,
        isDark: isDark,
        isArabic: isArabic,
      ),
      const SizedBox(width: 8),
      cu.SarAwareText(
        '${fmt(price)} ${widget.currencySymbol}',
        isNewSar: widget.isNewSar,
        style: baseStyle.copyWith(fontWeight: FontWeight.w700),
        maxLines: 1,
      ),
    ];

    if (abs != null && pct != null) {
      final arrow = abs > 0
          ? '▲'
          : (abs < 0)
          ? '▼'
          : '•';
      children.add(const SizedBox(width: 8));
      children.add(
        cu.SarAwareText(
          '($arrow ${fmtDelta(abs)} ${widget.currencySymbol} • ${fmtPct(pct)})',
          isNewSar: widget.isNewSar,
          style: baseStyle.copyWith(
            color: changeColor,
            fontWeight: FontWeight.w800,
          ),
          maxLines: 1,
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _ounceSegment({
    required TextStyle baseStyle,
    required bool isDark,
    required bool isArabic,
  }) {
    final ounce = _ouncePriceUsd ?? 0.0;
    final accent = Theme.of(context).colorScheme.primary;

    final label = isArabic ? 'الأونصة' : 'Ounce';
    final value = ounce > 0 ? ounce.toStringAsFixed(2) : '--';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? 0.16 : 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: accent.withValues(alpha: 0.55),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: baseStyle.copyWith(color: accent, fontWeight: FontWeight.w900),
            maxLines: 1,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$value USD',
          style: baseStyle.copyWith(fontWeight: FontWeight.w800),
          maxLines: 1,
        ),
      ],
    );
  }

  Widget _content({
    required TextStyle baseStyle,
    required bool isDark,
    required bool isArabic,
  }) {
    final header = isArabic ? 'تحديث سعر الذهب' : 'Gold Price Update';
    final headerStyle = baseStyle.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w900,
    );
    final sepStyle = baseStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w800,
    );

    if (_lastPrices.isEmpty) {
      final text = _loadError ??
          (isArabic
              ? 'تحديث سعر الذهب • جاري التحميل...'
              : 'Gold Price Update • Loading...');
      return Text(text, style: baseStyle, maxLines: 1);
    }

    const sep = '  •  ';

    if (isArabic) {
      // We reverse the list for RTL so the final order becomes:
      // header • ounce • 24 • 22 • 21 • 18
      final widgets = <Widget>[
        _segment(
          karat: 18,
          baseStyle: baseStyle,
          isDark: isDark,
          isArabic: isArabic,
        ),
        Text(sep, style: sepStyle, maxLines: 1),
        _segment(
          karat: 21,
          baseStyle: baseStyle,
          isDark: isDark,
          isArabic: isArabic,
        ),
        Text(sep, style: sepStyle, maxLines: 1),
        _segment(
          karat: 22,
          baseStyle: baseStyle,
          isDark: isDark,
          isArabic: isArabic,
        ),
        Text(sep, style: sepStyle, maxLines: 1),
        _segment(
          karat: 24,
          baseStyle: baseStyle,
          isDark: isDark,
          isArabic: isArabic,
        ),
        Text(sep, style: sepStyle, maxLines: 1),
        _ounceSegment(
          baseStyle: baseStyle,
          isDark: isDark,
          isArabic: isArabic,
        ),
        Text(sep, style: sepStyle, maxLines: 1),
        Text(header, style: headerStyle, maxLines: 1),
      ];

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: widgets.reversed.toList(),
      );
    }

    final widgets = <Widget>[
      Text(header, style: headerStyle, maxLines: 1),
      Text(sep, style: sepStyle, maxLines: 1),
      _ounceSegment(baseStyle: baseStyle, isDark: isDark, isArabic: isArabic),
      Text(sep, style: sepStyle, maxLines: 1),
      _segment(karat: 24, baseStyle: baseStyle, isDark: isDark, isArabic: isArabic),
      Text(sep, style: sepStyle, maxLines: 1),
      _segment(karat: 22, baseStyle: baseStyle, isDark: isDark, isArabic: isArabic),
      Text(sep, style: sepStyle, maxLines: 1),
      _segment(karat: 21, baseStyle: baseStyle, isDark: isDark, isArabic: isArabic),
      Text(sep, style: sepStyle, maxLines: 1),
      _segment(karat: 18, baseStyle: baseStyle, isDark: isDark, isArabic: isArabic),
    ];
    return Row(mainAxisSize: MainAxisSize.min, children: widgets);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final scheme = theme.colorScheme;
    final bg = scheme.surfaceContainerLowest.withValues(alpha: 0.92);

    final textStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'Cairo',
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );

    final effectiveStyle =
        textStyle ??
        const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600);

    return SafeArea(
      top: false,
      child: Container(
        height: 36,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.35),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: isDark ? 0.35 : 0.10),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: LayoutBuilder(builder: (context, constraints) {
            const horizontalPad = 12.0;
            const gap = 36.0;

            Widget buildContent() => _content(
              baseStyle: effectiveStyle,
              isDark: isDark,
              isArabic: widget.isArabic,
            );

            // Constant fallback until the true content width is measured.
            const fallbackWidth = 900.0;
            final cycleWidth =
                _measuredWidth > 0 ? _measuredWidth : fallbackWidth;
            final viewportWidth = constraints.maxWidth;
            final cycles = (viewportWidth / cycleWidth).ceil() + 4;

            // Keep pixel speed constant regardless of content width.
            const speed = 55.0;
            final targetMs =
                ((cycleWidth / speed).clamp(10.0, 22.0) * 1000).round();
            if (_controller.duration?.inMilliseconds != targetMs) {
              _controller.duration = Duration(milliseconds: targetMs);
              _controller
                ..reset()
                ..repeat();
            }

            // Build content tiles HERE (LayoutBuilder scope).
            // They are rebuilt only when data changes or the viewport
            // resizes — never on each 60 fps animation tick.
            Widget makeSlot() => RepaintBoundary(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: horizontalPad),
                child: Directionality(
                  textDirection:
                      widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
                  child: DefaultTextStyle(
                    style: effectiveStyle,
                    child: buildContent(),
                  ),
                ),
              ),
            );

            final copies = List.generate(cycles, (_) => makeSlot());

            // Hidden child used only to measure natural content width.
            final measureWidget = Offstage(
              offstage: true,
              child: RepaintBoundary(
                key: _measureKey,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: horizontalPad),
                  child: Directionality(
                    textDirection: widget.isArabic
                        ? TextDirection.rtl
                        : TextDirection.ltr,
                    child: DefaultTextStyle(
                      style: effectiveStyle,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          buildContent(),
                          const SizedBox(width: gap),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );

            // Flow: on each animation tick only paintChildren() runs.
            // No widget rebuild, no layout pass during scroll.
            return ClipRect(
              child: Flow(
                delegate: _TickerFlowDelegate(
                  animation: _controller,
                  cycleWidth: cycleWidth,
                  cycles: cycles,
                  isArabic: widget.isArabic,
                  viewportWidth: viewportWidth,
                ),
                children: [...copies, measureWidget],
              ),
            );
          }),
          ),
      ),
    );
  }
}
