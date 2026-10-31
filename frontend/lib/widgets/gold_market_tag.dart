import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../models/gold_prices.dart';

/// What a price strip says when the market is not live (PRICE-MARKET-1, the
/// owner 31 Oct 2026): «السوق مغلق · آخر سعر الجمعة 00:55» -- the price is the
/// last quote's, kept -- or «تعذّر تحديث السعر» when no source answered.
/// Nothing while the market is open.
class GoldMarketTag extends StatelessWidget {
  const GoldMarketTag({super.key, required this.market, this.color, this.compact = false});

  final GoldMarket market;
  final Color? color;
  final bool compact;

  static const _days = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];

  static String sayLastQuote(DateTime at) => '${_days[at.weekday - 1]} ${DateFormat('HH:mm').format(at)}';

  @override
  Widget build(BuildContext context) {
    if (!market.quiet) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    final text = market.unavailable
        ? 'تعذّر تحديث السعر'
        : market.lastQuoteAt == null
            ? 'السوق مغلق'
            : compact
                ? 'مغلق · ${sayLastQuote(market.lastQuoteAt!)}'
                : 'السوق مغلق · آخر سعر ${sayLastQuote(market.lastQuoteAt!)}';
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Row(
        key: const Key('gold-market-tag'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(market.unavailable ? Icons.cloud_off_rounded : Icons.lock_clock_rounded,
              size: compact ? 12 : 14, color: tint),
          const SizedBox(width: 4),
          Text(text,
              style: (compact ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
                  ?.copyWith(color: tint, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
