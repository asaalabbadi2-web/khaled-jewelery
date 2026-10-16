// «مركز التسكير» (ADR-048): the screen shows what the server's engine says --
// what waits, what it buys at the shop's own price, the five layers -- and
// computes none of it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/weight_position_screen.dart';

Map<String, dynamic> _position() => {
      'as_of': '2026-10-15',
      'open_cash': 251537.07, 'open_grams_sold': 290.7, 'open_count': 2, 'buys_now_grams': 604.0,
      'purchase_price': 416.44, 'purchase_price_source': 'متوسط شراء الكسر في آخر 7 أيام',
      'unrealized': 313.3, 'market_price': 436.09, 'unrealized_at_market': 286.1,
      'grams_per_price_percent': 5.98, 'oldest': '2026-10-08T18:45:30',
      'lots': [
        {'ref': 'بيع #1618', 'kind': 'sold', 'invoice_id': 3280, 'invoice_number': 1618, 'customer': 'عميل نقدي',
         'date': '2026-10-08T18:45:30', 'age_days': 7, 'cash': 13000.0, 'cash_open': 323.8, 'grams_open': 0.563,
         'expected_at_sale': 7.337, 'unrealized': 0.215},
        {'ref': 'إيرادات 2026-10-14', 'kind': 'revenue', 'invoice_id': null, 'invoice_number': null,
         'customer': null, 'date': '2026-10-14T23:59:00', 'age_days': 1, 'cash': 500.0, 'cash_open': 500.0,
         'grams_open': 0.0, 'expected_at_sale': null, 'unrealized': 1.2},
      ],
      'recent_closings': [
        {'kind': 'customer', 'invoice_id': 3400, 'date': '2026-10-15T10:00:00', 'cash': 4164.4, 'grams_in': 10.0,
         'grams_out': 7.0, 'result': 3.0},
      ],
      'where_the_riyals_are': {'in_hand': 390696.01, 'with_customers': 0.0, 'with_employees': 90576.0},
    };

Map<String, dynamic> _layers(double total) => {
      'trading': 4860.8, 'revenue_converted': 145.7, 'revenue_direct': 1.5, 'expense_direct': -243.7,
      'expense_cash': -2359.2, 'price_effect': total - (4860.8 + 145.7 + 1.5 - 243.7 - 2359.2),
    };

class _FakeApi extends ApiService {
  _FakeApi() : super(baseUrl: 'http://test');
  final List<String> performanceCalls = [];

  @override
  Future<Map<String, dynamic>> getWeightPosition({DateTime? asOf}) async => _position();

  @override
  Future<Map<String, dynamic>> getWeightPerformance({required DateTime startDate, required DateTime endDate}) async {
    performanceCalls.add('${startDate.month}-${startDate.day}');
    return {
      'period': {'weight_profit': 2627.0, 'layers': _layers(2627.0)},
      'months': [
        {'month': '2026-09', 'weight_profit': 274.4, 'layers': _layers(274.4)},
        {'month': '2026-10', 'weight_profit': 266.5, 'layers': _layers(266.5)},
      ],
    };
  }
}

Future<_FakeApi> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _FakeApi();
  await tester.pumpWidget(MaterialApp(home: WeightPositionScreen(api: api)));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('what waits, what it buys at your price, and the price\'s grip on it', (tester) async {
    await _pump(tester);
    expect(find.text('\u2066+313.3\u2069 غ'), findsWidgets);
    expect(find.byKey(const ValueKey('wp-sensitivity')), findsOneWidget);
    expect(find.textContaining('\u20666.0\u2069 غ'), findsWidgets);           // 5.98 per 1 %
    expect(find.text('متوسط شراء الكسر في آخر 7 أيام'), findsOneWidget);
  });

  testWidgets('the five layers and their total, as the server gives them', (tester) async {
    await _pump(tester);
    for (final name in ['① المتاجرة: ريالات المُباع التي عادت ذهبًا', '② إيرادات إضافية', '③ مصاريف وزنية',
                        '④ مصاريف نقدية', '⑤ أثر السعر على المفتوح']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    final total = tester.widget<Text>(find.byKey(const ValueKey('wp-period-total')));
    expect(total.data, '\u2066+2,627.0\u2069 غ');
  });

  testWidgets('the open sales, oldest first, a revenue among them', (tester) async {
    await _pump(tester);
    expect(find.text('بيع #1618 — عميل نقدي'), findsOneWidget);
    expect(find.text('إيرادات 2026-10-14'), findsOneWidget);
  });

  testWidgets('another period asks the server again', (tester) async {
    final api = await _pump(tester);
    expect(api.performanceCalls, ['1-1']);
    await tester.tap(find.text('هذا الشهر'));
    await tester.pumpAndSettle();
    expect(api.performanceCalls.length, 2);
    expect(api.performanceCalls.last, isNot('1-1'));
  });
}
