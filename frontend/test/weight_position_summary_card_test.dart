// «التسكير الآن» في لوحة المدير (ADR-048): البطاقة تعرض ما يقوله الخادم --
// المنتظر وما يشتريه، وأثر السعر، وانتظار أقدم بيع وتنبيه المالك، ومحقَّق
// الشهر -- ولا تحسب شيئًا، ولا تظهر لمن لا يقرأ التقارير المالية.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/utils/currency_utils.dart' as cu;
import 'package:frontend/screens/reports/weight_position_screen.dart';
import 'package:frontend/widgets/weight_position_summary_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _summary({bool raised = true, int count = 51}) => {
      'as_of': '2026-10-16', 'open_cash': 261822.43, 'open_count': count, 'buys_now_grams': 619.378,
      'closing_price': 428.93, 'price_now': 422.7182, 'price_now_source': 'سعر الكسر: السوق × 0.99',
      'expected_at_closing_price': 140.0, 'price_effect_since_sale': 8.869,
      'unrealized': 148.869, 'grams_per_price_percent': 6.132, 'oldest_date': '2026-10-08T19:37:30',
      'oldest_age_days': 8, 'alert': {'oldest_over_days': raised ? 7 : 10, 'raised': raised},
      'age_buckets': [
        {'key': 'recent', 'from_days': 0, 'to_days': 3, 'cash': 160000.0, 'count': 30, 'share': 0.611},
        {'key': 'aging', 'from_days': 4, 'to_days': 7, 'cash': 70000.0, 'count': 15, 'share': 0.2674},
        {'key': 'late', 'from_days': 8, 'to_days': null, 'cash': 31822.43, 'count': 6, 'share': 0.1215},
      ],
      'month_realized': 254.378,
    };

class _Api extends ApiService {
  _Api(this.answer) : super(baseUrl: 'http://test');
  final Future<Map<String, dynamic>?> Function() answer;
  int calls = 0;

  @override
  Future<Map<String, dynamic>?> getWeightPositionSummary() {
    calls++;
    return answer();
  }

  @override
  Future<Map<String, dynamic>> getWeightPosition({DateTime? asOf}) async => {
        'open_cash': 0.0, 'open_grams_sold': 0.0, 'open_count': 0, 'buys_now_grams': 0.0,
        'closing_price': null, 'price_now': 422.72, 'price_now_source': '', 'paid_average': 0.0,
        'paid_average_source': '', 'unrealized': 0.0, 'market_price': 0.0, 'grams_per_price_percent': 0.0, 'oldest': null, 'lots': [],
        'recent_closings': [], 'where_the_riyals_are': {'in_hand': 0.0, 'with_customers': 0.0, 'with_employees': 0.0},
      };

  @override
  Future<Map<String, dynamic>> getWeightPerformance({required DateTime startDate, required DateTime endDate}) async =>
      {'period': {'weight_profit': 0.0, 'layers': <String, dynamic>{}}, 'months': []};
}

Future<void> _pump(WidgetTester tester, ApiService api) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: WeightPositionSummaryCard(api: api)),
    ),
  ));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) {
  final at = find.byKey(ValueKey(key));
  final text = find.descendant(of: at, matching: find.byType(Text), matchRoot: true);
  return tester.widget<Text>(text.first).data!;
}

void main() {
  testWidgets('what waits is the headline; what it buys, the price\'s grip and the month are its tiles', (tester) async {
    await _pump(tester, _Api(() async => _summary()));
    expect(_text(tester, 'wps-open'), '\u2066261,822\u2069 ر.س');
    expect(_text(tester, 'wps-count'), 'من \u206651\u2069 بيعًا');
    expect(_text(tester, 'wps-buys'), 'يشتري الآن \u2066619.4\u2069 غ بسعر الكسر \u2066422.72\u2069');
    expect(_text(tester, 'wps-closing'), 'سعر التسكير \u2066428.93\u2069');
    expect(find.descendant(of: find.byKey(const ValueKey('wps-unrealized')), matching: find.text('\u2066+148.9\u2069 غ')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('wps-grip')), matching: find.text('\u2066−6.1\u2069 غ')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('wps-month')), matching: find.text('\u2066+254.4\u2069 غ')),
        findsOneWidget);
  });

  testWidgets('what waits, by age: the server\'s three parts and their shares', (tester) async {
    await _pump(tester, _Api(() async => _summary()));
    expect(find.byKey(const ValueKey('wps-ages')), findsOneWidget);
    expect(find.text('حتى \u20663\u2069 أيام  \u206661%\u2069'), findsOneWidget);
    expect(find.text('\u20664–7\u2069 أيام  \u206627%\u2069'), findsOneWidget);
    expect(find.text('أكثر من \u20667\u2069 أيام  \u206612%\u2069'), findsOneWidget);
  });

  testWidgets('the owner\'s alert shows when the server raises it, and only then', (tester) async {
    await _pump(tester, _Api(() async => _summary(raised: true)));
    expect(_text(tester, 'wps-oldest-text'), 'أقدم بيع ينتظر منذ \u20668\u2069 أيام — تجاوز \u20667\u2069');

    await _pump(tester, _Api(() async => _summary(raised: false)));
    expect(find.byKey(const ValueKey('wps-oldest')), findsNothing);
  });

  testWidgets('nothing waiting says so, and keeps the month', (tester) async {
    await _pump(tester, _Api(() async => _summary(count: 0)));
    expect(find.byKey(const ValueKey('wps-nothing')), findsOneWidget);
    expect(find.byKey(const ValueKey('wps-ages')), findsNothing);
    expect(find.byKey(const ValueKey('wps-month')), findsOneWidget);
  });

  testWidgets('a phone\'s width: everything still fits', (tester) async {
    tester.view.physicalSize = const Size(380, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: SingleChildScrollView(child: WeightPositionSummaryCard(api: _Api(() async => _summary())))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('wps-ages')), findsOneWidget);
  });

  testWidgets('the riyals in the shop\'s own currency: the new SAR graphic when it is set', (tester) async {
    SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'currency_symbol': cu.kSarNewSymbol})});
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(body: WeightPositionSummaryCard(api: _Api(() async => _summary()))),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('wps-open')), matching: find.byType(cu.SarSymbolImage)),
        findsOneWidget);
  });

  testWidgets('not for this reader: no card at all', (tester) async {
    await _pump(tester, _Api(() async => null));
    expect(find.byKey(const ValueKey('wps-card')), findsNothing);
    expect(find.byKey(const ValueKey('wps-error')), findsNothing);
  });

  testWidgets('a failure says so and can be retried -- no dead end', (tester) async {
    var fail = true;
    final api = _Api(() async {
      if (fail) throw Exception('network');
      return _summary();
    });
    await _pump(tester, api);
    expect(find.byKey(const ValueKey('wps-error')), findsOneWidget);
    fail = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(api.calls, 2);
    expect(find.byKey(const ValueKey('wps-card')), findsOneWidget);
  });

  testWidgets('a tap opens the centre', (tester) async {
    await _pump(tester, _Api(() async => _summary()));
    await tester.tap(find.byKey(const ValueKey('wps-card')));
    await tester.pumpAndSettle();
    expect(find.byType(WeightPositionScreen), findsOneWidget);
  });
}
