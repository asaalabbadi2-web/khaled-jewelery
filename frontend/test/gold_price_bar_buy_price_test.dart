// PRICE-BUY-1: the card shows the server's buy price (the market's times the
// settings' ratio) -- it multiplied by its own 0.98 before.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/gold_price_bar.dart';

void main() {
  testWidgets('the buy price is the server\'s, never computed', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: GoldPriceBar(
              goldPrice: 4161.86,
              goldPriceOpening: 4160.01,
              pricesPerGram: {
                '18': {'sell': 376.64, 'buy': 361.57},
                '21': {'sell': 439.41, 'buy': 421.83},
                '22': {'sell': 460.34, 'buy': 441.93},
                '24': {'sell': 502.19, 'buy': 482.10},
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('421.83'), findsWidgets);
    // 439.41 x 0.98 -- the app's own ratio -- appears nowhere.
    expect(find.textContaining('430.62'), findsNothing);
  });
}
