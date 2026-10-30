import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../models/gold_prices.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../theme/app_tokens.dart';
import 'dashboard_kit.dart';

/// The gold price, enough on its own (DASH-11, the owner 30 Oct 2026: «ما الذي
/// ينقصها لنكتفي بها من سعر الذهب» -- the main karat selling and buying, live
/// with its time, the day's move, the ounce). Every figure is the server's:
/// the live answer's (/gold_price, at its interval) and the day's
/// (/gold_price/24h?day=today); the change is two of its prices, as the home
/// screen's bar says it.
class DashboardGoldPriceCard extends StatelessWidget {
  const DashboardGoldPriceCard({
    super.key,
    required this.sell,
    required this.buy,
    required this.opening,
    required this.mainKarat,
    required this.at,
    required this.today,
    required this.isArabic,
    required this.money,
    this.onTap,
  });

  final GoldPrices sell;
  final GoldPrices buy;
  final GoldPrices opening;
  final int mainKarat;
  final DateTime? at;
  final Map<String, dynamic> today;
  final bool isArabic;
  final DashboardMoney money;
  final VoidCallback? onTap;

  static final _price = NumberFormat('#,##0.00');
  static final _time = DateFormat('HH:mm:ss');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    if (!sell.known) return const DashboardPanelSkeleton(lines: 4);

    final now = sell.of(mainKarat);
    final open = opening.of(mainKarat);
    final change = open > 0 ? now - open : null;
    final up = (change ?? 0) >= 0;
    final moveColor = up ? tones.ready.fg : tones.blocked.fg;
    final high = (today['high_main_karat'] as num?)?.toDouble();
    final low = (today['low_main_karat'] as num?)?.toDouble();
    final line = ((today['points'] as List?) ?? const [])
        .whereType<Map>()
        .map((p) => (p['price_main_karat'] as num?)?.toDouble() ?? 0.0)
        .where((v) => v > 0)
        .toList();
    final others = [24, 22, 18].where((k) => k != mainKarat && sell.of(k) > 0);

    return Material(
      key: const Key('dashboard-gold-price'),
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
                  Text(isArabic ? 'سعر الذهب' : 'Gold price',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(width: AppSpace.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
                    decoration: BoxDecoration(
                      color: tones.gold.fg.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(isArabic ? 'عيار $mainKarat' : '${mainKarat}K',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: tones.gold.fg, fontWeight: FontWeight.w800)),
                  ),
                  const Spacer(),
                  if (at != null) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: tones.ready.fg, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${isArabic ? 'حيّ' : 'Live'} · ${_time.format(at!.toLocal())}',
                      key: const Key('dashboard-gold-price-at'),
                      textDirection: TextDirection.ltr,
                      style: muted,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(isArabic ? 'بيع' : 'Sell', style: muted),
                        money.text(now,
                            style: dashboardFigure(theme.textTheme.headlineSmall, weight: FontWeight.w800)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(isArabic ? 'شراء' : 'Buy', style: muted),
                      money.text(buy.of(mainKarat), style: dashboardFigure(theme.textTheme.titleMedium)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.md,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (change != null)
                    Row(
                      key: const Key('dashboard-gold-price-move'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                            size: 14, color: moveColor),
                        Text(
                          '${_price.format(change.abs() / open * 100)}% (${_price.format(change.abs())})',
                          textDirection: TextDirection.ltr,
                          style: dashboardFigure(theme.textTheme.labelMedium, color: moveColor),
                        ),
                        const SizedBox(width: 4),
                        Text(isArabic ? 'منذ الافتتاح' : 'since opening', style: muted),
                      ],
                    ),
                  if (high != null && low != null)
                    Text(
                      isArabic
                          ? 'أعلى ${_price.format(high)} · أدنى ${_price.format(low)}'
                          : 'High ${_price.format(high)} · Low ${_price.format(low)}',
                      key: const Key('dashboard-gold-price-range'),
                      style: muted,
                    ),
                ],
              ),
              if (line.length > 1) ...[
                const SizedBox(height: AppSpace.sm),
                SizedBox(
                  height: 40,
                  child: LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                      lineTouchData: const LineTouchData(enabled: false),
                      lineBarsData: [
                        LineChartBarData(
                          spots: [for (final (i, v) in line.indexed) FlSpot(i.toDouble(), v)],
                          isCurved: true,
                          color: dashboardMark(context, moveColor),
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: true, color: moveColor.withValues(alpha: 0.10)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              // Each figure isolated left-to-right (U+2066 .. U+2069): in a line
              // read right-to-left «24: 452.10» came out «452.10 :24». The karat
              // in the text's colour, bold, apart from its price (the owner, 30 Oct
              // 2026: «تغميق أرقام العيارات لتمييز العيار عن سعره»).
              Text.rich(
                TextSpan(children: [
                  if (sell.ounceUsd > 0) ...[
                    // The word read right-to-left, its figure isolated.
                    TextSpan(
                        text: isArabic ? 'الأونصة ' : 'Ounce ',
                        style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w800)),
                    TextSpan(text: '\u2066\$${_price.format(sell.ounceUsd)}\u2069'),
                  ],
                  for (final (i, k) in others.indexed) ...[
                    if (i > 0 || sell.ounceUsd > 0) const TextSpan(text: '  ·  '),
                    const TextSpan(text: '\u2066'),
                    TextSpan(text: '$k', style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w800)),
                    TextSpan(text: ' ${_price.format(sell.of(k))}'),
                    const TextSpan(text: '\u2069'),
                  ],
                ]),
                key: const Key('dashboard-gold-price-others'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
