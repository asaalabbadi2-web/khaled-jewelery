// The home gold bar (the owner, 13 Nov 2026), every size, both themes.
//
// - It fits: nothing overflows, and it is no taller than it was (132).
// - Wide: the main karat's card and the chart share the width equally.
// - Every move is its own and the server's: each karat's, the ounce's; the
//   spread too. With none from the server, none is shown -- none is computed.
// - The market's state is said in every size (a phone hid it).
// - Narrow: two lines; a tap opens the chart and the other karats.
// - A new price is marked a moment.
// - The main karat is the one given.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/gold_prices.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/gold_price_bar.dart';
import 'package:frontend/widgets/gold_sparkline_enhanced.dart';

const _wasTall = 132.0;

// The main karat's sell price, moved by the tick tests.
final _sell21 = ValueNotifier<double>(412.35);

const _prices = {
  '18': {'sell': 353.45, 'buy': 347.25},
  '21': {'sell': 412.35, 'buy': 405.10},
  '22': {'sell': 432.00, 'buy': 424.40},
  '24': {'sell': 471.25, 'buy': 463.00},
};

// Each karat its own move -- 24 down while the others are up.
const _moves = {
  '18': {'change': 1.6, 'change_percent': 0.45, 'spread': 6.2},
  '21': {'change': 1.85, 'change_percent': 0.45, 'spread': 7.25},
  '22': {'change': 1.9, 'change_percent': 0.44, 'spread': 7.6},
  '24': {'change': -0.47, 'change_percent': -0.1, 'spread': 8.25},
};

List<GoldChartSeries> _series(DateTime now) => [
      GoldChartSeries(label: 'عيار 21', unit: 'ر.س', opening: 410.50, high: 412.47, low: 410.30, points: [
        for (var i = 0; i < 25; i++) SparklinePoint(time: now.subtract(Duration(hours: 24 - i)), price: 410.5 + i * 0.077),
      ]),
    ];

Future<void> _fonts() async {
  // Measured in the app's font, not the test font's square glyphs.
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold', 'ExtraBold', 'Black']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
}

Future<ValueNotifier<DateTime>> _pump(
  WidgetTester tester,
  ThemeData theme,
  double width, {
  int mainKarat = 21,
  Map<String, dynamic>? moves = _moves,
  Map<String, dynamic>? ounceMove = const {'change': -3.1, 'change_percent': -0.08},
  GoldMarket market = GoldMarket.live,
}) async {
  await _fonts();
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final now = DateTime.now();
  final date = ValueNotifier(now.subtract(const Duration(seconds: 20)));
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Column(
            children: [
              ValueListenableBuilder<DateTime>(
                valueListenable: date,
                builder: (context, at, _) => GoldPriceBar(
                  mainKarat: mainKarat,
                  goldPrice: 4105.20,
                  pricesPerGram: {
                    ..._prices,
                    '21': {'sell': _sell21.value, 'buy': 405.10},
                  },
                  movesPerGram: moves,
                  ounceMove: ounceMove,
                  goldPriceDate: at,
                  market: market,
                  chartSeries: _series(now),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return date;
}

// A move is isolated left to right (U+2066 .. U+2069): found by what it says.
Finder _in(Key key, String text) => find.descendant(of: find.byKey(key), matching: find.textContaining(text));

void main() {
  final themes = {'light': LightTheme.theme, 'dark': DarkTheme.theme};

  for (final width in [1280.0, 1366.0, 1440.0, 1920.0]) {
    for (final entry in themes.entries) {
      testWidgets('wide at $width (${entry.key}): fits; the card and the chart share it; each move its own',
          (tester) async {
        await _pump(tester, entry.value, width);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(GoldPriceBar)).height, lessThanOrEqualTo(_wasTall));
        final card = tester.getSize(find.byKey(const Key('gold-bar-main'))).width;
        final chart = tester.getSize(find.byKey(const Key('gold-bar-chart'))).width;
        expect((card - chart).abs(), lessThanOrEqualTo(1), reason: 'equal halves (the owner, 13 Nov 2026)');
        expect(find.byKey(const Key('gold-bar-toggle')), findsNothing);
        expect(find.textContaining('▲ 1.85 · 0.45%'), findsOneWidget, reason: "the main karat's move, the server's");
        expect(find.textContaining('\u2066▲ 1.85 · 0.45%\u2069'), findsOneWidget,
            reason: 'isolated left to right: the line does not turn its figures and signs about');
        expect(find.textContaining('الفارق  7.25'), findsOneWidget, reason: "its spread, the server's");
        expect(find.textContaining('▼ 0.10%'), findsOneWidget, reason: "24's own move -- not the main one's");
        expect(_in(const Key('gold-bar-ounce'), '▼ 3.10 · 0.08%'), findsOneWidget, reason: "the ounce's own");
        expect(_in(const Key('gold-bar-status'), 'مباشر'), findsOneWidget);
        expect(tester.getSize(find.byKey(const Key('gold-bar-karats'))).width, greaterThanOrEqualTo(230));
      });
    }
  }

  for (final width in [360.0, 390.0, 820.0, 1024.0, 1260.0]) {
    for (final entry in themes.entries) {
      testWidgets('narrow at $width (${entry.key}): two lines; a tap opens the chart and the karats', (tester) async {
        await _pump(tester, entry.value, width);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(GoldPriceBar)).height, lessThanOrEqualTo(_wasTall));
        expect(find.byKey(const Key('gold-bar-chart')), findsNothing, reason: 'closed: two lines');
        expect(_in(const Key('gold-bar-status'), 'مباشر'), findsOneWidget, reason: 'said on a phone too');

        await tester.tap(find.byKey(const Key('gold-bar-toggle')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50)); // the pulse never settles
        }
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('gold-bar-chart')), findsOneWidget);
        expect(_in(const Key('gold-bar-karat-24'), '▼ 0.10%'), findsOneWidget, reason: "24's own move");
        expect(_in(const Key('gold-bar-ounce'), '▼ 0.08%'), findsOneWidget, reason: "the ounce's own");

        await tester.tap(find.byKey(const Key('gold-bar-toggle')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byKey(const Key('gold-bar-chart')), findsNothing, reason: 'a second tap closes it');
      });
    }
  }

  testWidgets('no move from the server: none shown, none computed', (tester) async {
    await _pump(tester, LightTheme.theme, 1440, moves: null, ounceMove: null);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('الفارق  —'), findsOneWidget, reason: 'the spread is not made from sell and buy');
  });

  for (final (move, sell, says) in [('rose', 412.80, 'up'), ('fell', 411.90, 'down'), ('held', 412.35, 'none')]) {
    testWidgets('a new price that $move is marked ${says == 'none' ? 'not at all' : '$says a moment'}',
        (tester) async {
      final date = await _pump(tester, LightTheme.theme, 1440);
      final up = AppSemanticColors.light.ready.fg, down = AppSemanticColors.light.blocked.fg;
      Color behind() {
        final box = tester.widget<AnimatedContainer>(
            find.ancestor(of: find.byKey(const Key('gold-bar-sell')), matching: find.byType(AnimatedContainer)).first);
        return (box.decoration! as BoxDecoration).color!;
      }

      expect(behind().a, 0, reason: 'nothing marked before a new price');
      _sell21.value = sell;
      date.value = date.value.add(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 500));
      final mark = behind();
      switch (says) {
        case 'up':
          expect((mark.a > 0, mark.withValues(alpha: 1)), (true, up), reason: 'rose: green');
        case 'down':
          expect((mark.a > 0, mark.withValues(alpha: 1)), (true, down), reason: 'fell: red');
        default:
          expect(mark.a, 0, reason: 'held: no mark');
      }
      await tester.pump(const Duration(milliseconds: 1500));
      expect(behind().a, 0, reason: 'and the mark fades');
      _sell21.value = 412.35;
    });
  }

  testWidgets('the main karat is the one given -- 22 here: its card, and the others are 18, 21 and 24',
      (tester) async {
    await _pump(tester, LightTheme.theme, 1440, mainKarat: 22);
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.byKey(const Key('gold-bar-sell'))).data, '432.00');
    expect(find.textContaining('▲ 1.90 · 0.44%'), findsOneWidget, reason: "22's own move on its card");
    final karats = find.byKey(const Key('gold-bar-karats'));
    for (final k in [18, 21, 24]) {
      expect(find.descendant(of: karats, matching: find.text('عيار $k')), findsOneWidget);
    }
    expect(find.descendant(of: karats, matching: find.text('عيار 22')), findsNothing);
  });

  testWidgets('closed, it says so in the wide bar too', (tester) async {
    await _pump(tester, DarkTheme.theme, 1440,
        market: GoldMarket(open: false, lastQuoteAt: DateTime(2026, 10, 30, 0, 55)));
    expect(tester.takeException(), isNull);
    expect(_in(const Key('gold-bar-status'), 'السوق مغلق'), findsOneWidget);
    expect(find.text('آخر عرض: الجمعة 00:55'), findsOneWidget);
  });
}
