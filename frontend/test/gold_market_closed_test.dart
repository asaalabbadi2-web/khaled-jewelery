import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/gold_prices.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/gold_market_tag.dart';
import 'package:frontend/widgets/gold_price_bar.dart';

/// PRICE-MARKET-1 (the owner, 31 Oct 2026): a closed market is said closed --
/// «السوق مغلق · آخر سعر الجمعة 00:55» -- and a market no source answered for
/// says so; an open one says nothing more. The server's word (`market`).
void main() {
  // Friday 30 Oct 2026, 21:55 UTC -- Swissquote's last quote all that weekend.
  final fridayClose = DateTime.utc(2026, 10, 30, 21, 55);

  test('the answer\'s market is read, and an answer without one is open', () {
    final closed = GoldMarket.fromResponse({
      'market': {'open': false, 'last_quote_at': fridayClose.toIso8601String(), 'unavailable': false},
    });
    expect((closed.open, closed.quiet), (false, true));
    expect(closed.lastQuoteAt, fridayClose.toLocal());
    expect(GoldMarket.fromResponse({'price_usd_per_oz': 4000}).quiet, isFalse, reason: 'as before');
  });

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(theme: LightTheme.theme, home: Scaffold(body: Center(child: child))));

  testWidgets('closed, it says so and its last quote\'s day and time', (tester) async {
    final at = DateTime(2026, 10, 30, 0, 55);           // a Friday, the device's time
    await pump(tester, GoldMarketTag(market: GoldMarket(open: false, lastQuoteAt: at)));
    expect(find.text('السوق مغلق · آخر سعر الجمعة 00:55'), findsOneWidget);
  });

  testWidgets('no source answered: it says the price could not be refreshed', (tester) async {
    await pump(tester, const GoldMarketTag(market: GoldMarket(unavailable: true)));
    expect(find.text('تعذّر تحديث السعر'), findsOneWidget);
  });

  testWidgets('open, it says nothing more', (tester) async {
    await pump(tester, const GoldMarketTag(market: GoldMarket.live));
    expect(find.byKey(const Key('gold-market-tag')), findsNothing);
  });

  testWidgets('the home bar says the market closed instead of the price\'s age', (tester) async {
    tester.view.physicalSize = const Size(1440, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      GoldPriceBar(
        goldPrice: 3876.7,
        pricesPerGram: const {'21': {'sell': 395.12, 'buy': 380.10}, '24': {'sell': 452.1, 'buy': 434.0}},
        goldPriceDate: DateTime(2026, 10, 30, 0, 55),
        mainKarat: 21,
        market: GoldMarket(open: false, lastQuoteAt: DateTime(2026, 10, 30, 0, 55)),
      ),
    );
    expect(find.text('السوق مغلق\nالجمعة 00:55'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'it fits under the refresh button');
  });
}
