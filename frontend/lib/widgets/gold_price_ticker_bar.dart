import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';

class GoldPriceTickerBar extends StatefulWidget {
  final bool isArabic;

  /// Optional ounce price (USD/oz) provided by the parent.
  /// When set, the ticker renders from this value and updates immediately
  /// when it changes (useful after a manual refresh).
  final double? ouncePriceUsd;

  /// Optional opening ounce price (USD/oz) for today.
  /// When set, the delta shown in the ticker is computed against this value.
  final double? openingOuncePriceUsd;

  /// Refresh interval. If null, no auto refresh.
  final Duration? refreshInterval;

  /// Optional exchange rate for converting USD/oz to local currency per gram.
  /// If null, defaults to 3.75.
  final double? exchangeRate;

  /// Currency symbol shown alongside prices.
  final String currencySymbol;

  const GoldPriceTickerBar({
    super.key,
    required this.isArabic,
    this.ouncePriceUsd,
    this.openingOuncePriceUsd,
    this.refreshInterval,
    this.exchangeRate,
    this.currencySymbol = 'ر.س',
  });

  @override
  State<GoldPriceTickerBar> createState() => _GoldPriceTickerBarState();
}

class _GoldPriceTickerBarState extends State<GoldPriceTickerBar>
    with SingleTickerProviderStateMixin {
  final ApiService _api = ApiService();

  Timer? _timer;
  double? _ouncePriceUsd;
  double? _openingOuncePriceUsd;
  String? _loadError;

  late final AnimationController _controller;

  final Map<int, double> _lastPrices = {};
  final Map<int, double> _changeAbs = {};
  final Map<int, double> _changePct = {};
  final Map<int, double> _openingPrices = {};

  final GlobalKey _measureKey = GlobalKey();
  double _measuredWidth = 0.0;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();

    if (widget.openingOuncePriceUsd != null &&
        widget.openingOuncePriceUsd! > 0) {
      _applyOpeningOuncePrice(widget.openingOuncePriceUsd!);
    }

    if (widget.ouncePriceUsd != null && widget.ouncePriceUsd! > 0) {
      _applyOuncePrice(widget.ouncePriceUsd!, resetError: true);
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

    final nextOpening = widget.openingOuncePriceUsd;
    final prevOpening = oldWidget.openingOuncePriceUsd;
    if (nextOpening != null && nextOpening > 0) {
      if (prevOpening == null || (nextOpening - prevOpening).abs() > 1e-9) {
        _applyOpeningOuncePrice(nextOpening);
      }
    }

    final nextOunce = widget.ouncePriceUsd;
    final prevOunce = oldWidget.ouncePriceUsd;
    if (nextOunce != null && nextOunce > 0) {
      // If parent drives the value, prefer it and update immediately.
      if (prevOunce == null || (nextOunce - prevOunce).abs() > 1e-9) {
        _applyOuncePrice(nextOunce, resetError: true);
      }
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

  Color _karatAccentColor(int karat, {required bool isDark}) {
    switch (karat) {
      case 24:
        return AppColors.karat24;
      case 22:
        return AppColors.karat22;
      case 21:
        return AppColors.karat21;
      case 18:
        return AppColors.karat18;
      default:
        return AppColors.primaryGold;
    }
  }

  Color _trendColor(double delta, {required bool isDark}) {
    if (delta > 0) {
      return isDark ? const Color(0xFF66BB6A) : const Color(0xFF2E7D32);
    }
    if (delta < 0) {
      return isDark ? const Color(0xFFEF5350) : const Color(0xFFC62828);
    }
    return isDark ? Colors.white70 : Colors.black54;
  }

  double _rate() => widget.exchangeRate ?? 3.75;

  double _pricePerGramForKarat(int karat, double ouncePriceUsd) {
    final baseUsdPerGram = (ouncePriceUsd / 31.1035) * (karat / 24.0);
    return baseUsdPerGram * _rate();
  }

  void _applyOpeningOuncePrice(double openingOuncePriceUsd) {
    _openingOuncePriceUsd = openingOuncePriceUsd;

    final baseline = <int, double>{
      24: _pricePerGramForKarat(24, openingOuncePriceUsd),
      22: _pricePerGramForKarat(22, openingOuncePriceUsd),
      21: _pricePerGramForKarat(21, openingOuncePriceUsd),
      18: _pricePerGramForKarat(18, openingOuncePriceUsd),
    };

    setState(() {
      _openingPrices
        ..clear()
        ..addAll(baseline);
    });
  }

  void _applyOuncePrice(double ouncePriceUsd, {required bool resetError}) {
    final prevOunce = _ouncePriceUsd;
    _ouncePriceUsd = ouncePriceUsd;

    final current = <int, double>{
      24: _pricePerGramForKarat(24, ouncePriceUsd),
      22: _pricePerGramForKarat(22, ouncePriceUsd),
      21: _pricePerGramForKarat(21, ouncePriceUsd),
      18: _pricePerGramForKarat(18, ouncePriceUsd),
    };

    Map<int, double>? prevSnapshot;
    if (_openingPrices.isNotEmpty) {
      // Preferred baseline: today's opening.
      prevSnapshot = Map<int, double>.from(_openingPrices);
    } else if (_openingOuncePriceUsd != null && _openingOuncePriceUsd! > 0) {
      prevSnapshot = <int, double>{
        24: _pricePerGramForKarat(24, _openingOuncePriceUsd!),
        22: _pricePerGramForKarat(22, _openingOuncePriceUsd!),
        21: _pricePerGramForKarat(21, _openingOuncePriceUsd!),
        18: _pricePerGramForKarat(18, _openingOuncePriceUsd!),
      };
    } else if (_lastPrices.isNotEmpty) {
      // Fallback baseline: previous ticker update.
      prevSnapshot = Map<int, double>.from(_lastPrices);
    } else if (prevOunce != null && prevOunce > 0) {
      prevSnapshot = <int, double>{
        24: _pricePerGramForKarat(24, prevOunce),
        22: _pricePerGramForKarat(22, prevOunce),
        21: _pricePerGramForKarat(21, prevOunce),
        18: _pricePerGramForKarat(18, prevOunce),
      };
    }

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
  }

  Future<void> _load() async {
    try {
      // If the parent is driving the value, avoid polling overrides.
      if (widget.ouncePriceUsd != null && widget.ouncePriceUsd! > 0) {
        return;
      }
      final res = await _api.getGoldPricePublic();

      final openingRaw = res['opening_price_usd_per_oz'];
      final openingOunce = (openingRaw is String)
          ? double.tryParse(openingRaw)
          : (openingRaw as num?)?.toDouble();
      if (openingOunce != null && openingOunce > 0) {
        _applyOpeningOuncePrice(openingOunce);
      }

      final raw = res['price_usd_per_oz'];
      final ounce = (raw is String)
          ? double.tryParse(raw)
          : (raw as num?)?.toDouble();
      if (!mounted) return;
      if (ounce == null || ounce <= 0) {
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

      _applyOuncePrice(ounce, resetError: true);
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
      Text(
        '${fmt(price)} ${widget.currencySymbol}',
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
        Text(
          '($arrow ${fmtDelta(abs)} ${widget.currencySymbol} • ${fmtPct(pct)})',
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
    final accent = AppColors.primaryGold;

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
      color: AppColors.primaryGold,
      fontWeight: FontWeight.w900,
    );
    final sepStyle = baseStyle.copyWith(
      color: isDark ? Colors.white60 : Colors.black45,
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

    final bg = isDark
        ? const Color(0xFF0F1014).withValues(alpha: 0.92)
        : Colors.white.withValues(alpha: 0.92);

    final textStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'Cairo',
      fontWeight: FontWeight.w600,
      color: isDark ? Colors.white : Colors.black87,
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
            color: AppColors.primaryGold.withValues(alpha: 0.35),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const horizontalPad = 12.0;
                const gap = 36.0;

                Widget buildContent() => _content(
                  baseStyle: effectiveStyle,
                  isDark: isDark,
                  isArabic: widget.isArabic,
                );

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final renderObject = _measureKey.currentContext
                      ?.findRenderObject();
                  final box = renderObject is RenderBox ? renderObject : null;
                  if (box == null || !mounted) return;
                  final w = box.size.width;
                  if (w <= 0) return;
                  if ((w - _measuredWidth).abs() < 0.5) return;
                  setState(() => _measuredWidth = w);
                });

                // Safe fallback while width is not yet measured.
                final fallbackText = widget.isArabic
                    ? 'تحديث سعر الذهب • جاري التحميل...'
                    : 'Gold Price Update • Loading...';
                final fallbackPainter = TextPainter(
                  text: TextSpan(text: fallbackText, style: effectiveStyle),
                  textDirection: widget.isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  maxLines: 1,
                )..layout();
                final fallbackWidth =
                    fallbackPainter.size.width + (horizontalPad * 2) + gap;

                final cycleWidth = (_measuredWidth > 0)
                    ? _measuredWidth
                    : fallbackWidth;
                final viewportWidth = constraints.maxWidth;
                final cycles = (viewportWidth / cycleWidth).ceil() + 4;

                final speed = 55.0;
                final seconds = (cycleWidth / speed).clamp(10.0, 22.0);
                if (_controller.duration?.inMilliseconds !=
                    (seconds * 1000).round()) {
                  _controller.duration = Duration(
                    milliseconds: (seconds * 1000).round(),
                  );
                  _controller
                    ..reset()
                    ..repeat();
                }

                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final shift = _controller.value * cycleWidth;
                    final baseX = widget.isArabic
                        ? (-cycleWidth + shift)
                        : (viewportWidth - shift);

                    Widget chunk() {
                      return SizedBox(
                        width: cycleWidth,
                        child: UnconstrainedBox(
                          constrainedAxis: Axis.vertical,
                          alignment: widget.isArabic
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: horizontalPad,
                                ),
                                child: Directionality(
                                  textDirection: widget.isArabic
                                      ? TextDirection.rtl
                                      : TextDirection.ltr,
                                  child: DefaultTextStyle(
                                    style: effectiveStyle,
                                    child: buildContent(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: gap),
                            ],
                          ),
                        ),
                      );
                    }

                    final measureRow = Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: horizontalPad,
                      ),
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
                    );

                    return ClipRect(
                      child: Stack(
                        children:
                            (List.generate(cycles, (j) {
                              final i = j - 2;
                              final dx = baseX + (i * cycleWidth);
                              return Positioned(
                                left: dx,
                                top: 0,
                                bottom: 0,
                                child: Center(child: chunk()),
                              );
                            })..add(
                              Positioned(
                                left: -99999,
                                top: 0,
                                child: Offstage(
                                  offstage: true,
                                  child: RepaintBoundary(
                                    key: _measureKey,
                                    child: measureRow,
                                  ),
                                ),
                              ),
                            )),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
