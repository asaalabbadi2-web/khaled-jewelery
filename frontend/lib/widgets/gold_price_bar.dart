import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../theme/app_semantic_colors.dart';
import 'gold_sparkline_enhanced.dart';

class GoldPriceBar extends StatelessWidget {
  final double? goldPrice;
  final double? goldPriceOpening;
  final DateTime? goldPriceDate;
  final double exchangeRate;
  final int mainKarat;
  final bool isUpdating;
  final VoidCallback? onRefresh;

  final List<SparklinePoint> sparklinePoints;
  final VoidCallback? onSparklineTap;
  final bool isArabic;

  const GoldPriceBar({
    super.key,
    this.goldPrice,
    this.goldPriceOpening,
    this.goldPriceDate,
    this.exchangeRate = 3.75,
    this.mainKarat = 21,
    this.isUpdating = false,
    this.onRefresh,
    this.sparklinePoints = const [],
    this.onSparklineTap,
    this.isArabic = true,
  });

  List<int> _otherKarats(int main) {
    const all = [18, 21, 22, 24];
    return all.where((k) => k != main).toList();
  }

  double _gramPrice(double ouncePrice, int karat) =>
      (ouncePrice / 31.1035) * (karat / 24.0) * exchangeRate;

  String _formatPrice(double value) => NumberFormat('#,##0.00', 'en').format(value);

  String _formatPercent(double? value) {
    final normalized = value ?? 0;
    return '${normalized.abs().toStringAsFixed(2)}%';
  }

  /// SAR change per gram for a given karat (current vs opening).
  double? _changeAbsGram(int karat) {
    if (goldPrice == null || goldPriceOpening == null || goldPriceOpening == 0) {
      return null;
    }
    return _gramPrice(goldPrice!, karat) - _gramPrice(goldPriceOpening!, karat);
  }

  double? _changePercent() {
    if (goldPrice == null || goldPriceOpening == null || goldPriceOpening == 0) {
      return null;
    }
    return ((goldPrice! - goldPriceOpening!) / goldPriceOpening!) * 100;
  }

  String _relativeTimeLabel() {
    if (goldPriceDate == null) return 'منذ لحظات';
    final diff = DateTime.now().difference(goldPriceDate!);
    if (diff.inMinutes < 1) return 'منذ لحظات';
    if (diff.inHours < 1) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return DateFormat('dd/MM HH:mm', 'en').format(goldPriceDate!);
  }

  @override
  Widget build(BuildContext context) {
    final palette = _GoldBarPalette.of(context);
    final changePercent = _changePercent();
    final isUp = (changePercent ?? 0) >= 0;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [palette.surface3, palette.surface],
          ),
          border: Border(
            bottom: BorderSide(color: palette.divider, width: 1),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth <= 1100;

            if (compact) {
              return _buildPrimaryCard(
                palette: palette,
                ouncePrice: goldPrice,
                changePercent: changePercent,
                isUp: isUp,
              );
            }

            return Row(
              children: [
                _buildRefreshBlock(
                  palette: palette,
                  label: _relativeTimeLabel(),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 22,
                  child: _buildPrimaryCard(
                    palette: palette,
                    ouncePrice: goldPrice,
                    changePercent: changePercent,
                    isUp: isUp,
                  ),
                ),
                ..._otherKarats(mainKarat).expand((k) {
                  return [
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 10,
                      child: _buildOtherKaratCard(
                        palette: palette,
                        karat: k,
                        color: palette.karat(k),
                        ouncePrice: goldPrice,
                        trendText: _formatPercent(changePercent),
                        changeAbsGram: _changeAbsGram(k),
                        isUp: isUp,
                      ),
                    ),
                  ];
                }),
                const SizedBox(width: 14),
                _buildOunceBlock(
                  palette: palette,
                  ouncePrice: goldPrice,
                  openingPrice: goldPriceOpening,
                  isUp: isUp,
                  changePercent: changePercent,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildRefreshBlock({
    required _GoldBarPalette palette,
    required String label,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        InkWell(
          onTap: onRefresh,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: palette.surface2,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: isUpdating
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(palette.textMuted),
                      ),
                    )
                  : Icon(Icons.refresh_rounded, size: 18, color: palette.textMuted),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            color: palette.textSoft,
            fontFamily: 'Cairo',
          ),
        ),
      ],
    );
  }

  Widget _buildPrimaryCard({
    required _GoldBarPalette palette,
    required double? ouncePrice,
    required double? changePercent,
    required bool isUp,
  }) {
    final sell = ouncePrice != null ? _gramPrice(ouncePrice, mainKarat) : null;
    final buy = sell != null ? sell * 0.98 : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            palette.lightGold,
            palette.primaryGold.withValues(alpha: 0.15),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.primaryGold, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: palette.darkGold.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsetsDirectional.only(start: 12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: palette.primaryGold.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: palette.primaryGold,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '${mainKarat}K',
                      style: TextStyle(
                        color: palette.onGold,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'الأساسي',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: palette.darkGold,
                      fontFamily: 'Cairo',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _buildPrimaryValue(
                    palette: palette,
                    label: 'بيع / جم',
                    value: sell,
                    unit: 'ريال',
                    color: palette.sell,
                    changePercent: _formatPercent(changePercent),
                    isUp: isUp,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: _buildPrimaryValue(
                    palette: palette,
                    label: 'شراء / جم',
                    value: buy,
                    unit: 'ريال',
                    color: palette.buy,
                    changePercent: _formatPercent(changePercent),
                    isUp: isUp,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          if (sparklinePoints.isNotEmpty) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 160,
              child: GoldSparklineEnhanced(
                points: sparklinePoints,
                openingPrice: goldPriceOpening,
                isArabic: isArabic,
                height: 28,
                onTap: onSparklineTap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPrimaryValue({
    required _GoldBarPalette palette,
    required String label,
    required double? value,
    required String unit,
    required Color color,
    required String changePercent,
    required bool isUp,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: palette.textMuted,
            fontWeight: FontWeight.w600,
            fontFamily: 'Cairo',
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value != null ? _formatPrice(value) : '—',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                color: color,
                fontFamily: 'Cairo',
                height: 1,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: (isUp ? palette.up : palette.down).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '${isUp ? '▲' : '▼'} $changePercent',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: isUp ? palette.up : palette.down,
                  fontFamily: 'Cairo',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          unit,
          style: TextStyle(
            fontSize: 10,
            color: palette.textSoft,
            fontFamily: 'Cairo',
          ),
        ),
      ],
    );
  }

  Widget _buildOtherKaratCard({
    required _GoldBarPalette palette,
    required int karat,
    required Color color,
    required double? ouncePrice,
    required String trendText,
    double? changeAbsGram,
    required bool isUp,
  }) {
    final sell = ouncePrice != null ? _gramPrice(ouncePrice, karat) : null;
    final buy = sell != null ? sell * 0.98 : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'عيار $karat',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: (isUp ? palette.up : palette.down).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${isUp ? '▲' : '▼'} $trendText',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: isUp ? palette.up : palette.down,
                        fontFamily: 'Cairo',
                      ),
                    ),
                    if (changeAbsGram != null)
                      Text(
                        '${changeAbsGram >= 0 ? '+' : ''}${changeAbsGram.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w600,
                          color: (isUp ? palette.up : palette.down)
                              .withValues(alpha: 0.8),
                          fontFamily: 'Cairo',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                sell != null ? _formatPrice(sell) : '—',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: palette.sell,
                  fontFamily: 'Cairo',
                ),
              ),
              Text(
                ' / ',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.textSoft,
                  fontFamily: 'Cairo',
                ),
              ),
              Text(
                buy != null ? _formatPrice(buy) : '—',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: palette.buy,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOunceBlock({
    required _GoldBarPalette palette,
    required double? ouncePrice,
    required double? openingPrice,
    required bool isUp,
    required double? changePercent,
  }) {
    final amount = ouncePrice != null && openingPrice != null
        ? (ouncePrice - openingPrice).abs()
        : null;

    return Container(
      width: 150,
      padding: const EdgeInsetsDirectional.only(start: 14),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: palette.divider),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [palette.primaryGold, palette.goldDeep],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.currency_exchange, color: palette.onGold, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'الأونصة',
                  style: TextStyle(
                    fontSize: 10,
                    color: palette.textSoft,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Cairo',
                  ),
                ),
                Text(
                  ouncePrice != null ? '\$${_formatPrice(ouncePrice)}' : '—',
                  style: TextStyle(
                    fontSize: 14,
                    color: palette.text,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'Cairo',
                  ),
                ),
                Text(
                  amount != null && changePercent != null
                      ? '${isUp ? '▲' : '▼'} ${_formatPrice(amount)} (${changePercent.abs().toStringAsFixed(2)}%)'
                      : '—',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: isUp ? palette.up : palette.down,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Cairo',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ألوان شريط السعر من الثيم (ثيم-٠): كانت قيمًا ثابتة، فبقيت بطاقة العيار
/// الأساسي كريمية بنص باهت في الوضع الداكن.
class _GoldBarPalette {
  _GoldBarPalette.of(BuildContext context)
    : _cs = Theme.of(context).colorScheme,
      _tone = AppSemanticColors.of(context),
      _dark = Theme.of(context).brightness == Brightness.dark;

  final ColorScheme _cs;
  final AppSemanticColors _tone;
  final bool _dark;

  Color get primaryGold => _cs.primary;
  Color get goldDeep => Color.lerp(_cs.primary, _cs.shadow, 0.25)!;
  Color get onGold => _cs.onPrimary;
  Color get darkGold => _tone.gold.fg;
  Color get lightGold => _tone.gold.container;
  Color get surface => _dark ? _cs.surfaceContainerHigh : _cs.surfaceContainerLowest;
  Color get surface2 => _cs.surfaceContainer;
  Color get surface3 => _cs.surfaceContainerLow;
  Color get text => _cs.onSurface;
  Color get textMuted => _cs.onSurfaceVariant;
  Color get textSoft => _cs.onSurfaceVariant;
  Color get divider => _cs.outlineVariant;
  Color get border => _cs.outlineVariant;
  Color get up => _tone.ready.fg;
  Color get down => _tone.blocked.fg;
  Color get sell => _tone.invoiceSale.fg;
  Color get buy => _tone.invoicePurchase.fg;
  Color karat(int k) => _tone.karat(k).fg;
}
