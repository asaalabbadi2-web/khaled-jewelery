// The home bar's price chart (the owner, 13 Nov 2026): the main karat's line by
// default and the ounce's at a toggle, both the server's; the high and low over
// it, a hovered point's time and price in their place; a line of times under
// it; a tap opens the history and a drag scrubs the line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/gold_sparkline_enhanced.dart';

final _t0 = DateTime.utc(2026, 11, 12, 12);

// The answer names 21; 22's opening is there too and is not its.
const _openings = {'21': {'sell': 410.5}, '22': {'sell': 999.0}};

Map<String, dynamic> _answer({bool withKarat = true}) => {
      if (withKarat) 'main_karat': 21,
      if (withKarat) 'high_main_karat': 412.47,
      if (withKarat) 'low_main_karat': 410.3,
      'high_usd_per_oz': 4106.9,
      'low_usd_per_oz': 4084.1,
      'points': [
        for (var i = 0; i < 5; i++)
          {
            'timestamp': _t0.add(Duration(hours: 6 * i)).toIso8601String(),
            'price_usd_per_oz': 4086.2 + 4.75 * i,
            if (withKarat) 'price_main_karat': 410.5 + 0.4625 * i,
          },
      ],
    };

Future<int> _pump(WidgetTester tester, List<GoldChartSeries> series) async {
  var taps = 0;
  tester.view.physicalSize = const Size(400, 300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: GoldSparklineEnhanced(series: series, onTap: () => taps++),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return taps;
}

String _range(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('gold-chart-range'))).textSpan!.toPlainText();

void main() {
  test('the two lines from the answer: the main karat first, each with its own high and low', () {
    final series = GoldChartSeries.fromResponse(_answer(), openingPricesPerGram: _openings, openingOunce: 4086.2);
    expect([for (final s in series) s.label], ['عيار 21', 'الأونصة']);
    expect([for (final s in series) s.unit], ['ر.س', r'$']);
    expect((series[0].high, series[0].low, series[0].opening), (412.47, 410.3, 410.5));
    expect((series[1].high, series[1].low, series[1].opening), (4106.9, 4084.1, 4086.2));
    expect(series[0].points.last.price, closeTo(412.35, 0.001));
    final as22 = GoldChartSeries.fromResponse({..._answer(), 'main_karat': 22}, openingPricesPerGram: _openings);
    expect((as22[0].label, as22[0].opening), ('عيار 22', 999.0),
        reason: "the line's karat is the answer's, and so is its opening -- no karat fixed here");
    expect(series[0].points.first.time, _t0.toLocal());
    expect([for (final s in GoldChartSeries.fromResponse(_answer(withKarat: false))) s.label], ['الأونصة'],
        reason: 'an answer without the main karat: the ounce alone');
    expect(GoldChartSeries.fromResponse(const {}), isEmpty);
    expect([for (final s in GoldChartSeries.fromResponse(_answer(), mainKarat: 24)) s.label], ['الأونصة'],
        reason: "an answer for 21 while the main karat is 24: no karat line -- never another karat's");
    expect([for (final s in GoldChartSeries.fromResponse(_answer(), mainKarat: 21)) s.label], ['عيار 21', 'الأونصة']);
  });

  testWidgets('the main karat by default; the toggle shows the ounce, in dollars', (tester) async {
    await _pump(tester, GoldChartSeries.fromResponse(_answer(), openingPricesPerGram: _openings, openingOunce: 4086.2));
    expect(find.byKey(const Key('gold-chart-series-0')), findsOneWidget);
    expect(_range(tester), contains('412.47 ر.س'));
    expect(_range(tester), contains('410.30 ر.س'));
    await tester.tap(find.byKey(const Key('gold-chart-series-1')));
    await tester.pump();
    expect(_range(tester), contains(r'$4,106.90'));
    expect(_range(tester), isNot(contains('ر.س')));
    expect(find.byKey(const Key('gold-chart-times')), findsOneWidget);
    expect(
        tester.widgetList<Text>(find.descendant(of: find.byKey(const Key('gold-chart-times')), matching: find.byType(Text))),
        hasLength(5));
  });

  testWidgets('one line: no toggle, its label', (tester) async {
    await _pump(tester, GoldChartSeries.fromResponse(_answer(withKarat: false)));
    expect(find.byKey(const Key('gold-chart-series-0')), findsNothing);
    expect(find.text('الأونصة'), findsOneWidget);
  });

  testWidgets('a drag scrubs the line and says the point; a tap opens the history', (tester) async {
    var taps = 0;
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: GoldSparklineEnhanced(series: GoldChartSeries.fromResponse(_answer()), onTap: () => taps++),
          ),
        ),
      ),
    ));
    await tester.pump();
    final plot = find.byType(CustomPaint).last;
    final gesture = await tester.startGesture(tester.getCenter(plot));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(find.byKey(const Key('gold-chart-hovered')), findsOneWidget);
    expect(find.byKey(const Key('gold-chart-range')), findsNothing, reason: 'the point in their place');
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const Key('gold-chart-range')), findsOneWidget);
    expect(taps, 0, reason: 'a drag is not a tap');

    await tester.tap(plot);
    await tester.pump();
    expect(taps, 1);
  });
}
