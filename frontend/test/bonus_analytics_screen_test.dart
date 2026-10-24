import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/bonus_analytics_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

/// The analytics say what the server says was granted (bonus study م3و): the
/// page summed every bonus it loaded, a rejected one as given, and «a year»
/// was every bonus ever.
class _Api extends ApiService {
  _Api({this.empty = false}) : super(baseUrl: 'http://test');

  final bool empty;
  final windows = <(String, String)>[];

  @override
  Future<Map<String, dynamic>> getBonusAnalytics({required String from, required String to}) async {
    windows.add((from, to));
    if (empty) {
      return {'statuses': {'pending': 0, 'approved': 0, 'paid': 0, 'rejected': 0, 'reversed': 0}};
    }
    return {
      'granted_total': 5900.0, 'pending_total': 700.0, 'approval_rate': 0.75,
      'statuses': {'pending': 1, 'approved': 1, 'paid': 2, 'rejected': 1, 'reversed': 0},
      'by_employee': [
        {'employee_id': 16, 'name': 'مسعد المهري', 'amount': 5500.0, 'count': 2},
        {'employee_id': 18, 'name': 'يوسف الشعبي', 'amount': 400.0, 'count': 1},
      ],
      'by_rule': [
        {'rule_id': 1, 'name': 'الهدف الشهري', 'amount': 5500.0, 'share': 0.9322},
        {'rule_id': null, 'name': 'يدوية', 'amount': 400.0, 'share': 0.0678},
      ],
      'by_month': [
        {'month': '2026-08', 'amount': 3000.0}, {'month': '2026-09', 'amount': 2900.0},
      ],
      'by_department': [{'department': 'المبيعات', 'amount': 5900.0, 'employees': 2}],
    };
  }
}

Future<_Api> _pump(WidgetTester tester, {ThemeData? theme, bool empty = false, Size size = const Size(1200, 2000)}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api(empty: empty);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: settings,
    child: MaterialApp(
      theme: theme ?? LightTheme.theme,
      home: Scaffold(body: BonusAnalyticsScreen(api: api, isArabic: true)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('the granted and the pending are the server\'s, apart', (tester) async {
    await _pump(tester);
    expect(find.descendant(of: find.byKey(const Key('analytics-granted')), matching: find.textContaining('5,900')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('analytics-pending')), matching: find.textContaining('700')),
        findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('يدوية'), findsOneWidget);
  });

  testWidgets('a year is a year, and another period asks the server again', (tester) async {
    final api = await _pump(tester);
    final fmt = DateFormat('yyyy-MM-dd');
    final today = DateTime.now();
    expect(api.windows.single, (fmt.format(today.subtract(const Duration(days: 365))), fmt.format(today)));
    await tester.tap(find.text('30 يومًا'));
    await tester.pumpAndSettle();
    expect(api.windows.last.$1, fmt.format(today.subtract(const Duration(days: 30))));
  });

  testWidgets('nothing in the period says so, with a way to a longer one', (tester) async {
    await _pump(tester, empty: true);
    expect(find.text('لا مكافآت في آخر سنة'), findsOneWidget);
  });

  testWidgets('it reads in the dark theme', (tester) async {
    await _pump(tester, theme: DarkTheme.theme);
    expectNoTextVanishesOnDark(tester);
    expectNoLightSurfaceOnDark(tester);
  });

  testWidgets('it fits a phone', (tester) async {
    await _pump(tester, size: const Size(360, 2400));
    expect(tester.takeException(), isNull);
    expect(find.text('مسعد المهري'), findsOneWidget);
  });
}
