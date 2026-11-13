import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../models/gold_prices.dart';
import '../theme/app_semantic_colors.dart';
import 'gold_market_tag.dart';
import 'gold_sparkline_enhanced.dart';

/// The home screen's gold price bar (the owner, 13 Nov 2026).
///
/// Every figure is the server's: each karat's price a gram (`prices_per_gram`,
/// PRICE-BUY-1), each karat's move since the day's opening and its spread
/// (`moves_per_gram`), the ounce's own move (`ounce_move`). The bar computes
/// none, and shows a karat's move as that karat's -- not the main one's.
///
/// Wide: the market's state and the price's age; the main karat's card and
/// the chart sharing what is left equally, the card's parts spread across its
/// half; the other karats a column; the ounce. Narrow (phone, iPad): two lines
/// no taller than the bar was, and a tap opens the chart and the other karats.
/// A new price is marked a moment behind the sell price, green if it rose and
/// red if it fell. Red and green say up
/// and down only; a karat's tag is neither.
class GoldPriceBar extends StatefulWidget {
  /// The world ounce, in dollars.
  final double? goldPrice;

  /// {'21': {'sell': .., 'buy': ..}}: the server's prices a gram, by karat.
  final Map<String, dynamic>? pricesPerGram;

  /// {'21': {'change': .., 'change_percent': .., 'spread': ..}}: the server's.
  final Map<String, dynamic>? movesPerGram;

  /// {'change': .., 'change_percent': ..}: the ounce's own, the server's.
  final Map<String, dynamic>? ounceMove;
  final DateTime? goldPriceDate;

  /// Open, closed or unavailable, as the price's answer says (PRICE-MARKET-1).
  final GoldMarket market;
  final int mainKarat;
  final bool isUpdating;
  final VoidCallback? onRefresh;

  /// The chart's lines, the server's: the main karat's first (the default).
  final List<GoldChartSeries> chartSeries;
  final VoidCallback? onSparklineTap;
  final bool isArabic;

  const GoldPriceBar({
    super.key,
    this.goldPrice,
    this.pricesPerGram,
    this.movesPerGram,
    this.ounceMove,
    this.goldPriceDate,
    this.market = GoldMarket.live,
    required this.mainKarat,
    this.isUpdating = false,
    this.onRefresh,
    this.chartSeries = const [],
    this.onSparklineTap,
    this.isArabic = true,
  });

  /// Below this width (the bar's own, inside its padding) the bar is the
  /// narrow one: the wide one's parts do not fit side by side.
  static const wideFrom = 1230.0;

  @override
  State<GoldPriceBar> createState() => _GoldPriceBarState();
}

class _GoldPriceBarState extends State<GoldPriceBar> {
  static final _money = NumberFormat('#,##0.00', 'en');

  /// The last price's move: up, down, or none -- marked a moment, then faded.
  bool? _tick;
  bool _expanded = false;
  Timer? _fade;

  @override
  void didUpdateWidget(covariant GoldPriceBar old) {
    super.didUpdateWidget(old);
    // A new price: marked a moment green if the main karat's sell price rose,
    // red if it fell -- the two server prices compared, nothing computed -- and
    // not at all if it did not move (the owner, 13 Nov 2026).
    final was = _sellOf(old), now = _sellOf(widget);
    if (widget.goldPriceDate != old.goldPriceDate && was != null && now != null && now != was) {
      _fade?.cancel();
      setState(() => _tick = now > was);
      _fade = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _tick = null);
      });
    }
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  // ── the server's figures ──

  static double? _sellOf(GoldPriceBar bar) {
    final row = bar.pricesPerGram?['${bar.mainKarat}'];
    final v = row is Map ? row['sell'] : null;
    return v is num ? v.toDouble() : null;
  }

  double? _price(int karat, String side) {
    final row = widget.pricesPerGram?['$karat'];
    final v = row is Map ? row[side] : null;
    return v is num ? v.toDouble() : null;
  }

  double? _move(int karat, String key) {
    final row = widget.movesPerGram?['$karat'];
    final v = row is Map ? row[key] : null;
    return v is num ? v.toDouble() : null;
  }

  double? _ounce(String key) {
    final v = widget.ounceMove?[key];
    return v is num ? v.toDouble() : null;
  }

  List<int> get _others => [for (final k in const [18, 21, 22, 24]) if (k != widget.mainKarat) k];

  String _fmt(double? v) => v == null ? '—' : _money.format(v);

  /// «▲ 1.85 · 0.45%», or the percent alone -- isolated left to right, so the
  /// right-to-left line does not turn its figures and signs about.
  String _say(double? change, double? percent, {bool amount = true}) {
    if (percent == null) return '—';
    final arrow = (change ?? percent) >= 0 ? '▲' : '▼';
    final pct = '${percent.abs().toStringAsFixed(2)}%';
    final said = amount && change != null ? '$arrow ${_money.format(change.abs())} · $pct' : '$arrow $pct';
    return '\u2066$said\u2069';
  }

  Color _moveColor(_Palette p, double? v) => v == null ? p.muted : (v >= 0 ? p.up : p.down);

  // ── the market and the price's age ──

  String get _age {
    final m = widget.market;
    if (!m.open && !m.unavailable) {
      return m.lastQuoteAt == null ? '' : 'آخر عرض: ${GoldMarketTag.sayLastQuote(m.lastQuoteAt!)}';
    }
    final at = widget.goldPriceDate;
    if (at == null) return '';
    final age = DateTime.now().difference(at);
    final ago = age.inMinutes < 1
        ? 'لحظات'
        : age.inHours < 1
            ? '${age.inMinutes} دقيقة'
            : age.inHours < 24
                ? '${age.inHours} ساعة'
                : DateFormat('dd/MM HH:mm', 'en').format(at);
    return m.unavailable ? 'آخر سعر قبل $ago' : 'آخر سعر منذ $ago';
  }

  Widget _status(_Palette p) {
    final m = widget.market;
    final (label, fg, bg) = m.unavailable
        ? ('تعذّر التحديث', p.down, p.downBg)
        : !m.open
            ? ('السوق مغلق', p.muted, p.neutralBg)
            : ('مباشر', p.up, p.upBg);
    return Container(
      key: const Key('gold-bar-status'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: p.type.bodySmall!.copyWith(color: fg, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _refresh(_Palette p, {double size = 36}) => Semantics(
        button: true,
        label: 'تحديث السعر الآن',
        child: InkResponse(
          onTap: widget.isUpdating ? null : widget.onRefresh,
          radius: size / 2 + 4,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: p.card, shape: BoxShape.circle, border: Border.all(color: p.border)),
            child: Center(
              child: widget.isUpdating
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.8, color: p.muted),
                    )
                  : Icon(Icons.refresh_rounded, size: 18, color: p.muted),
            ),
          ),
        ),
      );

  // ── the parts ──

  Widget _badge(_Palette p, {double size = 44}) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: p.gold, borderRadius: BorderRadius.circular(10)),
          child: Center(
            child: Text('${widget.mainKarat}',
                style: p.type.headlineSmall!.copyWith(color: p.onGold, fontWeight: FontWeight.w800)),
          ),
        ),
        if (size >= 40) ...[
          const SizedBox(height: 2),
          Text('الأساسي', style: p.type.bodySmall!.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
        ],
      ]);

  /// «بيع / جم» on its tint over the price -- the price in the text's colour.
  Widget _priceBlock(_Palette p, String label, Color fg, Color bg, double? value, TextStyle figure,
      {bool? tick, Key? key}) {
    final mark = tick == null ? p.up.withValues(alpha: 0) : (tick ? p.up : p.down).withValues(alpha: 0.14);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: mark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
          child: Text(label, style: p.type.bodySmall!.copyWith(color: fg, fontWeight: FontWeight.w700)),
        ),
        Text(_fmt(value), key: key, style: figure.copyWith(color: p.ink, height: 1.15)),
      ]),
    );
  }

  /// The main karat's card: its parts spread across the card's half of the
  /// bar; where the half is narrower than they are, they shrink together.
  Widget _mainCard(_Palette p) {
    final k = widget.mainKarat;
    final change = _move(k, 'change'), percent = _move(k, 'change_percent');
    final figure = p.type.displayMedium!.copyWith(fontWeight: FontWeight.w800);
    final parts = [
      _badge(p),
      _priceBlock(p, 'بيع / جم', p.sale, p.saleBg, _price(k, 'sell'), figure,
          tick: _tick, key: const Key('gold-bar-sell')),
      _priceBlock(p, 'شراء / جم', p.buy, p.buyBg, _price(k, 'buy'), figure, key: const Key('gold-bar-buy')),
      Container(width: 1, height: 52, color: p.border),
      Column(
        key: const Key('gold-bar-main-move'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: 'الفارق  ', style: p.type.bodySmall!.copyWith(color: p.muted)),
            TextSpan(
              text: _fmt(_move(k, 'spread')),
              style: p.type.titleLarge!.copyWith(color: p.ink, fontWeight: FontWeight.w700),
            ),
          ])),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _moveColor(p, percent).withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'منذ الافتتاح  ', style: p.type.bodySmall!.copyWith(color: p.muted)),
              TextSpan(
                text: _say(change, percent),
                style: p.type.bodySmall!.copyWith(color: _moveColor(p, percent), fontWeight: FontWeight.w800),
              ),
            ])),
          ),
        ],
      ),
    ];
    return Container(
      key: const Key('gold-bar-main'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: LayoutBuilder(
        builder: (context, box) => FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final (i, part) in parts.indexed) ...[if (i > 0) const SizedBox(width: 12), part],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chartPanel(_Palette p, {double height = 44}) => Container(
        key: const Key('gold-bar-chart'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.border),
        ),
        child: GoldSparklineEnhanced(
          series: widget.chartSeries,
          isArabic: widget.isArabic,
          onTap: widget.onSparklineTap,
          height: height,
        ),
      );

  /// One karat in a line: its tag, its sell and buy, its own move.
  Widget _karatRow(_Palette p, int karat) {
    final percent = _move(karat, 'change_percent');
    final figure = p.type.bodyMedium!.copyWith(color: p.ink, fontWeight: FontWeight.w700);
    final letter = p.type.bodySmall!.copyWith(fontWeight: FontWeight.w800);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: p.karat(karat), shape: BoxShape.circle)),
        const SizedBox(width: 6),
        SizedBox(width: 50, child: Text('عيار $karat', style: figure)),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'ب ', style: letter.copyWith(color: p.sale)),
              TextSpan(text: _fmt(_price(karat, 'sell')), style: figure),
              const TextSpan(text: '   '),
              TextSpan(text: 'ش ', style: letter.copyWith(color: p.buy)),
              TextSpan(text: _fmt(_price(karat, 'buy')), style: figure),
            ])),
          ),
        ),
        const SizedBox(width: 6),
        Text(_say(null, percent, amount: false),
            style: p.type.bodySmall!.copyWith(color: _moveColor(p, percent), fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _ounceBlock(_Palette p) {
    final change = _ounce('change'), percent = _ounce('change_percent');
    return Column(
      key: const Key('gold-bar-ounce'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('الأونصة', style: p.type.bodySmall!.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
        Text(widget.goldPrice == null ? '—' : '\$${_fmt(widget.goldPrice)}',
            style: p.type.headlineMedium!.copyWith(color: p.ink, fontWeight: FontWeight.w800)),
        Text(_say(change, percent),
            style: p.type.bodySmall!.copyWith(color: _moveColor(p, percent), fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _wide(_Palette p, double width) {
    final karats = (230 + (width - GoldPriceBar.wideFrom) * 0.3).clamp(230.0, 360.0);
    // As tall as its tallest part, the three karats' column: the chart, which
    // measures its width as it lays out, cannot be asked its height first.
    return SizedBox(
      height: 96,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 150,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: _status(p),
                ),
              ),
              const SizedBox(width: 6),
              _refresh(p),
            ]),
            const SizedBox(height: 6),
            Text(_age, key: const Key('gold-bar-age'), style: p.type.bodySmall!.copyWith(color: p.muted)),
          ]),
        ),
        const SizedBox(width: 14),
        // The card and the chart share what is left equally (the owner, 13 Nov 2026).
        Expanded(child: _mainCard(p)),
        if (widget.chartSeries.isNotEmpty) ...[
          const SizedBox(width: 14),
          Expanded(child: _chartPanel(p)),
        ],
        const SizedBox(width: 14),
        SizedBox(
          width: karats,
          child: Column(
            key: const Key('gold-bar-karats'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (i, k) in _others.indexed) ...[
                if (i > 0) const SizedBox(height: 4),
                _karatRow(p, k),
              ],
            ],
          ),
        ),
        const SizedBox(width: 14),
        Container(width: 1, color: p.border),
        const SizedBox(width: 14),
        SizedBox(width: 120, child: _ounceBlock(p)),
      ]),
    );
  }

  Widget _narrow(_Palette p) {
    final k = widget.mainKarat;
    final percent = _move(k, 'change_percent');
    final figure = p.type.displaySmall!.copyWith(fontWeight: FontWeight.w800);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(key: const Key('gold-bar-main'), children: [
        _badge(p, size: 34),
        const SizedBox(width: 6),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _priceBlock(p, 'بيع', p.sale, p.saleBg, _price(k, 'sell'), figure,
                  tick: _tick, key: const Key('gold-bar-sell')),
              _priceBlock(p, 'شراء', p.buy, p.buyBg, _price(k, 'buy'), figure, key: const Key('gold-bar-buy')),
            ]),
          ),
        ),
        const Spacer(),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('الفارق', style: p.type.bodySmall!.copyWith(color: p.muted)),
          Text(_fmt(_move(k, 'spread')), style: p.type.titleMedium!.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
        ]),
      ]),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            expanded: _expanded,
            label: _expanded ? 'إخفاء الرسم والعيارات' : 'عرض الرسم والعيارات',
            child: InkWell(
              key: const Key('gold-bar-toggle'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36),
                child: Row(children: [
                  Flexible(
                    flex: 0,
                    child: FittedBox(fit: BoxFit.scaleDown, child: _status(p)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_age,
                        key: const Key('gold-bar-age'),
                        overflow: TextOverflow.ellipsis,
                        style: p.type.bodySmall!.copyWith(color: p.muted)),
                  ),
                  Text(_say(null, percent, amount: false),
                      style: p.type.bodySmall!.copyWith(color: _moveColor(p, percent), fontWeight: FontWeight.w800)),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: p.muted),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _refresh(p, size: 32),
      ]),
      AnimatedSize(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: _expanded ? _details(p) : const SizedBox(width: double.infinity),
      ),
    ]);
  }

  /// Opened under the narrow bar: the chart the width of the screen, then the
  /// other karats and the ounce, each with its own move.
  Widget _details(_Palette p) {
    Widget chip(Key key, String label, Color dot, String value, String move, Color moveColor) => Expanded(
          child: Container(
            key: key,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: p.type.bodySmall!.copyWith(color: p.muted, fontWeight: FontWeight.w700)),
                ),
              ]),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(value, style: p.type.bodyLarge!.copyWith(color: p.ink, fontWeight: FontWeight.w800)),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(move, style: p.type.bodySmall!.copyWith(color: moveColor, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        );
    final ouncePct = _ounce('change_percent');
    return Column(
      key: const Key('gold-bar-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        if (widget.chartSeries.isNotEmpty) ...[_chartPanel(p, height: 56), const SizedBox(height: 8)],
        Row(children: [
          for (final (i, k) in _others.indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            chip(Key('gold-bar-karat-$k'), 'عيار $k', p.karat(k), _fmt(_price(k, 'sell')),
                _say(null, _move(k, 'change_percent'), amount: false), _moveColor(p, _move(k, 'change_percent'))),
          ],
          const SizedBox(width: 6),
          chip(const Key('gold-bar-ounce'), 'الأونصة', p.gold,
              widget.goldPrice == null ? '—' : '\$${_fmt(widget.goldPrice)}',
              _say(null, ouncePct, amount: false), _moveColor(p, ouncePct)),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _Palette.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        decoration: BoxDecoration(color: p.bar, border: Border(bottom: BorderSide(color: p.border))),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: LayoutBuilder(
          builder: (context, box) =>
              box.maxWidth >= GoldPriceBar.wideFrom ? _wide(p, box.maxWidth) : _narrow(p),
        ),
      ),
    );
  }
}

/// The bar's colours and type, the theme's. Up green and down red are the
/// moves' alone; the sell and buy tints are the invoices' (ICONS-1).
class _Palette {
  _Palette.of(BuildContext context)
      : _cs = Theme.of(context).colorScheme,
        _tone = AppSemanticColors.of(context),
        type = Theme.of(context).textTheme;

  final ColorScheme _cs;
  final AppSemanticColors _tone;

  /// The theme's type: the bar's text is set in it, not in written sizes.
  final TextTheme type;

  Color get bar => _cs.surfaceContainerLow;
  Color get card => _cs.surfaceContainerLowest;
  Color get border => _cs.outlineVariant;
  Color get ink => _cs.onSurface;
  Color get muted => _cs.onSurfaceVariant;
  Color get gold => _cs.primary;
  Color get onGold => _cs.onPrimary;
  Color get up => _tone.ready.fg;
  Color get upBg => _tone.ready.container;
  Color get down => _tone.blocked.fg;
  Color get downBg => _tone.blocked.container;
  Color get neutralBg => _cs.surfaceContainerHighest;
  Color get sale => _tone.invoiceSale.fg;
  Color get saleBg => _tone.invoiceSale.container;
  Color get buy => _tone.invoicePurchase.fg;
  Color get buyBg => _tone.invoicePurchase.container;
  Color karat(int k) => _tone.karat(k).fg;
}
