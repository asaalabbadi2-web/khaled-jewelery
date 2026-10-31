import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/gold_prices.dart';
import '../providers/settings_provider.dart';

/// An invoice's price strip, live (PRICE-LIVE-1, the owner 29 Oct 2026: «الخيار
/// الأول»): it reads the server's price at its interval (15 seconds), and only
/// the strip moves -- what the invoice's lines are priced at is the screen's own
/// price, read when it opens and when a line is added, so no total moves while
/// it is written.
mixin LiveGoldPrices<T extends StatefulWidget> on State<T> {
  Timer? _liveTimer;

  /// What the strip shows: the server's selling and buy prices, newest.
  GoldPrices liveSell = GoldPrices.none;
  GoldPrices liveBuy = GoldPrices.none;

  /// The same answer's day opening, when the price was saved, and the main
  /// karat it was asked for (the settings', the server's) -- for the manager's
  /// gold price card (DASH-11); the invoices' strips read only the two above.
  GoldPrices liveOpening = GoldPrices.none;
  DateTime? liveAt;
  int? liveMainKarat;

  /// Open, closed or unavailable, as the same answer says (PRICE-MARKET-1).
  GoldMarket liveMarket = GoldMarket.live;

  /// The price answer the strip reads -- the screen's api (a fake in tests).
  Future<Map<String, dynamic>> fetchLiveGoldPrice();

  /// The strip shows [answer] -- a price the screen read itself.
  void showLiveGoldPrice(Map<String, dynamic> answer) {
    final sell = GoldPrices.fromResponse(answer);
    if (!sell.known || !mounted) return;
    setState(() {
      liveSell = sell;
      liveBuy = GoldPrices.fromResponse(answer, buy: true);
      liveOpening = GoldPrices.openingFromResponse(answer);
      liveAt = DateTime.tryParse('${answer['date'] ?? ''}');
      liveMainKarat = (answer['main_karat'] as num?)?.toInt();
      liveMarket = GoldMarket.fromResponse(answer);
    });
  }

  /// Starts at the settings' interval; none when the price is not refreshed.
  void startLiveGoldPrices() {
    _liveTimer?.cancel();
    final interval = context.read<SettingsProvider>().goldPriceTickerRefreshInterval;
    if (interval == null) return;
    _liveTimer = Timer.periodic(interval, (_) async {
      try {
        showLiveGoldPrice(await fetchLiveGoldPrice());
      } catch (_) {
        // The strip keeps the price it shows; the next tick tries again.
      }
    });
  }

  void stopLiveGoldPrices() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }
}
