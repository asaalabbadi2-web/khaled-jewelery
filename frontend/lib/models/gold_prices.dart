/// Each karat's gold price a gram, as the server prices it (OFFICE-PRICE-1).
///
/// The price is the closing office's (the owner, 28 Oct 2026): its karats are
/// not 24k times their fineness -- 21k is the kilo / 1143 less a discount -- so a
/// screen reads a karat's price from here and never makes it from 24k.
class GoldPrices {
  const GoldPrices(this._sell, {this.ounceUsd = 0.0});

  static const none = GoldPrices({});

  final Map<int, double> _sell;

  /// The world ounce the prices were made from, in dollars -- shown, not priced from.
  final double ounceUsd;

  /// From a GET /gold_price answer: `prices_per_gram` {'21': {'sell': .., 'buy': ..}}
  /// -- the selling price, or with [buy] the buy price (the settings' ratio of it).
  factory GoldPrices.fromResponse(Map<String, dynamic>? data, {bool buy = false}) {
    final sell = <int, double>{};
    final perGram = data?['prices_per_gram'];
    if (perGram is Map) {
      perGram.forEach((key, row) {
        final karat = int.tryParse('$key');
        final value = row is Map ? _asDouble(row[buy ? 'buy' : 'sell']) : 0.0;
        if (karat != null && value > 0) sell[karat] = value;
      });
    }
    return GoldPrices(sell, ounceUsd: _asDouble(data?['price_usd_per_oz']));
  }

  /// The day's opening from the same answer: `opening_prices_per_gram`, each
  /// karat by the terms its own price was saved with.
  factory GoldPrices.openingFromResponse(Map<String, dynamic>? data) => GoldPrices.fromResponse({
    'prices_per_gram': data?['opening_prices_per_gram'],
    'price_usd_per_oz': data?['opening_price_usd_per_oz'],
  });

  /// The price a gram of [karat]. A karat the server does not price (it prices
  /// 18, 21, 22 and 24) is 24k by its fineness.
  double of(num karat) {
    final own = _sell[karat.round()];
    if (own != null && own > 0) return own;
    final k24 = _sell[24] ?? 0.0;
    return k24 > 0 ? k24 * karat / 24.0 : 0.0;
  }

  double get k24 => of(24);

  bool get known => k24 > 0;

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse('${value ?? ''}') ?? 0.0;
  }
}

/// The world's gold market, as the server says it (PRICE-MARKET-1, the owner
/// 31 Oct 2026): closed when the source's last quote is old -- the weekend, a
/// holiday -- and unavailable when no source answered. From a /gold_price
/// answer's `market`; an answer without it is an open market, as before.
class GoldMarket {
  const GoldMarket({this.open = true, this.lastQuoteAt, this.unavailable = false});

  static const live = GoldMarket();

  final bool open;
  final DateTime? lastQuoteAt;
  final bool unavailable;

  factory GoldMarket.fromResponse(Map<String, dynamic>? data) {
    final m = data?['market'];
    if (m is! Map) return live;
    return GoldMarket(
      open: m['open'] != false,
      lastQuoteAt: DateTime.tryParse('${m['last_quote_at'] ?? ''}')?.toLocal(),
      unavailable: m['unavailable'] == true,
    );
  }

  /// Whether the screens say anything but «حيّ».
  bool get quiet => !open || unavailable;
}
