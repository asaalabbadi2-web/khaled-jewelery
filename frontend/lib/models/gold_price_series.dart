/// A point of a price line: its time and its price.
class SparklinePoint {
  final DateTime time;
  final double price;
  const SparklinePoint({required this.time, required this.price});
}

/// One line the home bar's chart can show (the owner, 13 Nov 2026): the main
/// karat's price a gram by default, the ounce at a toggle. Every figure is the
/// server's -- the points, the day's opening, the high and the low; the chart
/// draws them and computes none.
class GoldChartSeries {
  const GoldChartSeries({
    required this.label,
    required this.unit,
    required this.points,
    this.opening,
    this.high,
    this.low,
  });

  /// «عيار 21», «الأونصة».
  final String label;

  /// The settings' currency for a gram, «$» for the ounce.
  final String unit;
  final List<SparklinePoint> points;
  final double? opening;
  final double? high;
  final double? low;

  /// The two lines of a GET /gold_price/24h answer: the main karat's
  /// (`price_main_karat`, `high_main_karat`, `low_main_karat`) first, then the
  /// ounce's. An answer without the main karat's gives the ounce's alone.
  /// [currency]: the settings' symbol (SettingsProvider.currencySymbolText),
  /// never one written here.
  /// The main karat's opening is read from [openingPricesPerGram] (GET
  /// /gold_price's `opening_prices_per_gram`) by the karat this answer names --
  /// the line and its opening are one karat's, whatever the settings say now.
  ///
  /// [mainKarat], the one the screen shows: an answer for another karat -- made
  /// before the settings changed it -- gives no karat line, the ounce's alone,
  /// until the answer for this one comes (the owner, 13 Nov 2026: the chart
  /// stayed 21's after the main karat became 24).
  static List<GoldChartSeries> fromResponse(
    Map<String, dynamic>? answer, {
    Map<String, dynamic>? openingPricesPerGram,
    double? openingOunce,
    int? mainKarat,
    required String currency,
  }) {
    final raw = answer?['points'];
    final rows = raw is List ? raw.whereType<Map>().toList() : const <Map>[];
    List<SparklinePoint> line(String key) => [
          for (final r in rows)
            if (DateTime.tryParse('${r['timestamp'] ?? ''}') case final t?)
              if (_num(r[key]) case final p? when p > 0) SparklinePoint(time: t.toLocal(), price: p),
        ];
    final karat = _num(answer?['main_karat'])?.round();
    final karatLine = line('price_main_karat');
    final ounceLine = line('price_usd_per_oz');
    return [
      if (karat != null && karatLine.isNotEmpty && (mainKarat == null || karat == mainKarat))
        GoldChartSeries(
          label: 'عيار $karat',
          unit: currency,
          points: karatLine,
          opening: _num((openingPricesPerGram?['$karat'] as Map?)?['sell']),
          high: _num(answer?['high_main_karat']),
          low: _num(answer?['low_main_karat']),
        ),
      if (ounceLine.isNotEmpty)
        GoldChartSeries(
          label: 'الأونصة',
          unit: r'$',
          points: ounceLine,
          opening: openingOunce,
          high: _num(answer?['high_usd_per_oz']),
          low: _num(answer?['low_usd_per_oz']),
        ),
    ];
  }

  static double? _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
}
