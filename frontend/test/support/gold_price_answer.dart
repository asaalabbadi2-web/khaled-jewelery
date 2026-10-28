/// A GET /gold_price answer as the server gives it: each karat's own price
/// (`prices_per_gram`, OFFICE-PRICE-1) beside `price_24k`. Here a price saved
/// with no office terms -- each karat 24k by its fineness, as the server
/// prices one -- and the buy price the settings' [ratio] of it.
Map<String, dynamic> goldPriceAnswer(
  double price24k, {
  double ratio = 0.98,
  double? ounceUsd,
}) =>
    {
      'price_24k': price24k,
      if (ounceUsd != null) 'price_usd_per_oz': ounceUsd,
      'prices_per_gram': {
        for (final k in const [24, 22, 21, 18])
          '$k': {
            'sell': double.parse((price24k * k / 24).toStringAsFixed(2)),
            'buy': double.parse((price24k * k / 24 * ratio).toStringAsFixed(2)),
          },
      },
    };
