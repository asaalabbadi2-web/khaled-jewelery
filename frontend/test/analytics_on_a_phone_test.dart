// The analytics dashboard on a phone (the owner, 13 Nov 2026: «في الشاشات
// الصغيره اجعل العرض كبطاقات»): each group of the breakdown is a card -- its
// figures by name, a zero left out -- not eleven columns slid sideways. An
// iPad keeps the table. Nothing overflows. Made-up figures.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/analytics_dashboard_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _group(String group, double grams, double cashIn, double cashOut) => {
      'group': group, 'weight_24k': grams * 0.875, 'weight_main': grams, 'weight_out_24k': grams * 0.875,
      'weight_out_main': grams, 'weight_in_24k': 0.0, 'weight_in_main': 0.0, 'cash_in': cashIn,
      'cash_out': cashOut, 'amount_cash': cashIn - cashOut, 'line_count': 42,
    };

class _Api extends ApiService {
  @override
  Future<Map<String, dynamic>> getAnalyticsSummary({
    required String groupBy,
    DateTime? startDate,
    DateTime? endDate,
    bool postedOnly = true,
  }) async => {
        'items': [_group('بيع', 1234.5, 520000.0, 0.0), _group('شراء من عميل', 300.25, 0.0, 115000.75)],
        'totals': _group('all', 1534.75, 520000.0, 115000.75),
      };
}

Future<List<String>> _open(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({'app_settings': '{"main_karat": 21}'});
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final errors = <String>[];
  final before = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
  try {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AnalyticsDashboardScreen(api: _Api(), isArabic: true),
        ),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  } finally {
    FlutterError.onError = before;
  }
  return errors;
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  for (final (device, size) in [('iPhone SE', const Size(375, 4000)), ('iPhone', const Size(390, 4000))]) {
    testWidgets('on an $device each group is a card, and nothing overflows', (tester) async {
      final errors = await _open(tester, size);
      expect(errors, isEmpty);
      expect(find.byType(DataTable), findsNothing);
      final buys = find.byKey(const ValueKey('analytics-row-1'));
      expect(buys, findsOneWidget);
      expect(find.descendant(of: buys, matching: find.text('الكاش الخارج')), findsOneWidget);
      expect(find.descendant(of: buys, matching: find.text('الكاش الداخل')), findsNothing, reason: 'a zero left out');
      expect(find.descendant(of: buys, matching: find.text('صافي التدفق النقدي')), findsOneWidget);
      // the period's cash flow reads on one line -- three tiles a row broke it a
      // digit a line (the owner, 13 Nov 2026)
      final cash = find.textContaining('404,999.25').first;
      expect(tester.getSize(cash).height, lessThan(40));
    });
  }

  testWidgets('an iPad keeps the table', (tester) async {
    final errors = await _open(tester, const Size(744, 4000));
    expect(errors, isEmpty);
    expect(find.byType(DataTable), findsOneWidget);
  });
}
