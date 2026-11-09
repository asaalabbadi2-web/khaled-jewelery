import 'package:flutter/material.dart';

import '../models/gold_prices.dart';
import '../utils/currency_utils.dart' show formatAmount;
import 'gold_market_tag.dart';

/// The gold price strip under an invoice's title: the ounce, each karat's
/// gram, the main karat marked -- the market's state when it is quiet
/// (PRICE-MARKET-1). One strip for the invoices (it was copied into each).
/// Its prices scroll on a narrow screen rather than overflow it: an iPhone
/// cut 18k off and printed a striped band at its edge (9 Nov 2026).
class InvoicePriceStrip extends StatelessWidget {
  const InvoicePriceStrip({
    super.key,
    required this.ounce,
    required this.karats,
    required this.mainKarat,
    required this.market,
    required this.foreground,
    required this.background,
    required this.unit,
  });

  /// The ounce's price, and whether prices are known yet.
  final GoldPrices ounce;

  /// Each karat's gram: the sell price, or the buy price on a purchase.
  final GoldPrices karats;
  final int mainKarat;
  final GoldMarket market;
  final Color foreground;
  final Color background;

  /// The unit after the prices («ر.س/جم»), as each screen writes it.
  final Widget unit;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: !ounce.known
            ? Text(
                'جاري تحميل سعر الذهب...',
                style: style?.copyWith(color: foreground.withValues(alpha: 0.7)),
              )
            : Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('invoice-price-strip'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          Icon(Icons.monetization_on_outlined, size: 12, color: foreground),
                          const SizedBox(width: 4),
                          Text(
                            'أونصة: \$${formatAmount(ounce.ounceUsd, decimals: 0)}',
                            style: style?.copyWith(color: foreground, fontWeight: FontWeight.w700),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: Text('|', style: style?.copyWith(color: foreground.withValues(alpha: 0.55))),
                          ),
                          for (final k in const [24, 22, 21, 18])
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Text(
                                '${k}k: ${formatAmount(karats.of(k))}',
                                style: style?.copyWith(
                                  color: foreground,
                                  decoration: k == mainKarat ? TextDecoration.underline : null,
                                  fontWeight: k == mainKarat ? FontWeight.w800 : FontWeight.w500,
                                ),
                              ),
                            ),
                          unit,
                        ],
                      ),
                    ),
                  ),
                  if (market.quiet) ...[
                    const SizedBox(width: 6),
                    GoldMarketTag(market: market, compact: true, color: foreground),
                  ],
                ],
              ),
      ),
    );
  }
}
