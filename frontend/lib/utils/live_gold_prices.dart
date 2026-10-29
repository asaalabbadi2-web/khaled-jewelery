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

  /// The price answer the strip reads -- the screen's api (a fake in tests).
  Future<Map<String, dynamic>> fetchLiveGoldPrice();

  /// The strip shows [answer] -- a price the screen read itself.
  void showLiveGoldPrice(Map<String, dynamic> answer) {
    final sell = GoldPrices.fromResponse(answer);
    if (!sell.known || !mounted) return;
    setState(() {
      liveSell = sell;
      liveBuy = GoldPrices.fromResponse(answer, buy: true);
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
