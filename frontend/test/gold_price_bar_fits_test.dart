// The main karat card's sell and buy prices fit their columns (found on the
// home screen, 14 Oct 2026: «430.42» drawn over «439.20» at 1280 wide, both
// themes). A price that does not fit scales down; it never overflows.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/gold_price_bar.dart';
import 'package:frontend/widgets/gold_sparkline_enhanced.dart';

Future<void> _pump(WidgetTester tester, ThemeData theme, double width) async {
  // Measured in the app's font, not the test font's square glyphs.
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold', 'ExtraBold', 'Black']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: GoldPriceBar(
            goldPrice: 4161.86,
            goldPriceOpening: 4160.01,
            goldPriceDate: DateTime(2026, 10, 14, 9),
            sparklinePoints: [
              SparklinePoint(time: DateTime(2026, 10, 13, 9), price: 4160.01),
              SparklinePoint(time: DateTime(2026, 10, 14, 1), price: 4161.43),
              SparklinePoint(time: DateTime(2026, 10, 14, 9), price: 4161.86),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final width in [1024.0, 1280.0, 1440.0]) {
    for (final entry in {'light': LightTheme.theme, 'dark': DarkTheme.theme}.entries) {
      testWidgets('the main karat prices fit at $width (${entry.key})', (tester) async {
        await _pump(tester, entry.value, width);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
