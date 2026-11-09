// An invoice's title bar on the shop's devices (the owner, 9 Nov 2026).
//
// On an iPhone the title comes first: the user's name is not shown, the
// actions kept stay buttons, the others fold under «⋮» -- and do what their
// buttons did. On an iPad mini and wider, all as they were. The price strip
// carries every karat on a phone, scrolled, never cut.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/gold_prices.dart';
import 'package:frontend/theme/app_breakpoints.dart';
import 'package:frontend/widgets/invoice_bar_actions.dart';
import 'package:frontend/widgets/invoice_price_strip.dart';

Future<List<String>> _bar(WidgetTester tester, Size size) async {
  final pressed = <String>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('فاتورة شراء جديدة'),
          actions: invoiceBarActions(
            context,
            user: const Text('سعد', key: Key('user')),
            keep: [
              IconButton(tooltip: 'إكمال لاحقاً', icon: const Icon(Icons.schedule),
                  onPressed: () => pressed.add('later')),
            ],
            fold: [
              IconButton(tooltip: 'تحديث سعر الذهب', icon: const Icon(Icons.refresh),
                  onPressed: () => pressed.add('price')),
              IconButton(tooltip: 'إعدادات الفاتورة', icon: const Icon(Icons.settings),
                  onPressed: () => pressed.add('settings')),
            ],
          ),
        ),
      ),
    ),
  ));
  return pressed;
}

void main() {
  test('the devices by width', () {
    expect(AppBreakpoints.forWidth(375), DeviceClass.phone);
    expect(AppBreakpoints.forWidth(430), DeviceClass.phone);
    expect(AppBreakpoints.forWidth(744), DeviceClass.tablet);
    expect(AppBreakpoints.forWidth(1133), DeviceClass.wide);
  });

  testWidgets('on an iPhone: no name, one button, the rest under «⋮» doing what they did', (tester) async {
    final pressed = await _bar(tester, const Size(390, 844));
    expect(find.byKey(const Key('user')), findsNothing);
    expect(find.byTooltip('إكمال لاحقاً'), findsOneWidget);
    expect(find.byTooltip('تحديث سعر الذهب'), findsNothing);
    await tester.tap(find.byKey(const Key('invoice-bar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعدادات الفاتورة'));
    await tester.pumpAndSettle();
    expect(pressed, ['settings']);
  });

  testWidgets('on an iPad mini: as it was', (tester) async {
    await _bar(tester, const Size(744, 1133));
    expect(find.byKey(const Key('user')), findsOneWidget);
    expect(find.byTooltip('تحديث سعر الذهب'), findsOneWidget);
    expect(find.byKey(const Key('invoice-bar-more')), findsNothing);
  });

  testWidgets('the price strip carries every karat on a phone, scrolled', (tester) async {
    tester.view.physicalSize = const Size(375, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prices = GoldPrices(
      {for (final k in [24, 22, 21, 18]) k: 420.0 * k / 24},
      ounceUsd: 2650.0,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvoicePriceStrip(
          ounce: prices, karats: prices, mainKarat: 21, market: GoldMarket.live,
          foreground: Colors.white, background: Colors.black, unit: const Text('ر.س/جم'),
        ),
      ),
    ));
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
    for (final k in [24, 22, 21, 18]) {
      expect(find.textContaining('${k}k:'), findsOneWidget);
    }
    expect(find.byKey(const Key('invoice-price-strip')), findsOneWidget);
  });
}
