import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/sales_race_management_screen.dart';
import 'package:frontend/widgets/race_rank_row.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

/// A change of the race's points settings is said in figures before it is
/// saved (bonus study م3د; the owner: «حيّ مع تحذير ومعاينة»): the settings are
/// read live, so the whole open month is measured by the new ones.
class _Manager extends AuthProvider {
  @override
  String get username => 'manager';
  @override
  bool hasPermission(String key) => true;
}

class _Api extends ApiService {
  _Api() : super(baseUrl: 'http://test');

  Map<String, dynamic>? previewed;
  Map<String, dynamic>? saved;

  static const _config = {
    'enabled': true, 'default_period': 'today', 'enabled_periods': ['today', 'week', 'month'],
    'points_source': 'profit_cash', 'cash_amount_per_point': 50.0, 'points_per_gram': 10.0,
    'points_per_invoice': 1.0, 'weekly_sales_target_weight': 125.0, 'monthly_sales_target_weight': 500.0,
  };

  @override
  Future<Map<String, dynamic>> getSalesRaceConfig() async => Map<String, dynamic>.from(_config);

  @override
  Future<Map<String, dynamic>> getHomeLeaderboard({String period = 'today', String metric = 'weight'}) async => {
        'metric': 'points',
        'champion': {'name': 'مسعد المهري'},
        'admin_summary': {'total_sales_amount': 120000.0, 'total_purchase_amount': 30000.0, 'total_points': 2400},
        'team_goal': {'period': 'monthly', 'period_label': 'الشهري', 'metric': 'points', 'unit': 'نقطة',
                      'value': 4200, 'target': 5000, 'progress': 0.84, 'reached': false, 'employees': 5},
        'ranking': [
          for (final (i, name) in ['مسعد المهري', 'يوسف الشعبي', 'صالح العبادي', 'خالد الحربي'].indexed)
            {'name': name, 'score': 1200.0 - i * 200, 'share': 0.4 - i * 0.1, 'count': 10 - i,
             'sales_amount': 40000.0 - i * 5000, 'purchase_amount': 5000.0,
             'crowns': i == 0 ? 7 : 0, 'goals_reached': i == 0 ? 5 : (i == 1 ? 2 : 0)},
        ],
      };

  @override
  Future<Map<String, dynamic>> previewSalesRaceConfig(Map<String, dynamic> points) async {
    previewed = points;
    return {
      'period_start': '2026-10-01',
      'employees': [
        {'employee_id': 16, 'employee': 'مسعد المهري', 'points_now': 1200, 'points_new': 600},
      ],
      'rules': [
        {'rule_id': 1, 'rule': 'الهدف الشهري', 'employee_id': 16, 'amount_now': 3000.0, 'amount_new': 0.0},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> updateSalesRaceConfig(Map<String, dynamic> data) async {
    saved = data;
    return {..._config, ...data};
  }
}

Future<_Api> _pump(WidgetTester tester, {ThemeData? theme, bool settingsTab = true}) async {
  SharedPreferences.setMockInitialValues({});
  await initializeDateFormatting('ar');
  await initializeDateFormatting('en');
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api();
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AuthProvider>(create: (_) => _Manager()),
      ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
    ],
    child: MaterialApp(theme: theme ?? LightTheme.theme, home: SalesRaceManagementScreen(api: api)),
  ));
  await tester.pumpAndSettle();
  if (settingsTab) {
    await tester.tap(find.text('الإعدادات'));
    await tester.pumpAndSettle();
  }
  return api;
}

Future<void> _changeAndSave(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextField, 'ريال ربح لكل نقطة (فواتير البيع)'), '100');
  final save = find.text('حفظ الإعدادات');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a changed riyal per point is said in figures, and going back saves nothing', (tester) async {
    final api = await _pump(tester);
    await _changeAndSave(tester);
    expect(api.previewed, {'cash_amount_per_point': 100.0}, reason: 'only what changed is previewed');
    expect(find.text('1,200 ← 600 نقطة'), findsOneWidget);
    expect(find.textContaining('3,000.00 ← 0.00'), findsOneWidget);
    expect(find.textContaining('للفترة الجارية كلها منذ 2026-10-01'), findsOneWidget);
    await tester.tap(find.text('تراجع'));
    await tester.pumpAndSettle();
    expect(api.saved, isNull);

    await _changeAndSave(tester);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(api.saved!['cash_amount_per_point'], 100.0);
  });

  testWidgets('a save that changes no points setting asks nothing', (tester) async {
    final api = await _pump(tester);
    final save = find.text('حفظ الإعدادات');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(api.previewed, isNull);
    expect(api.saved, isNotNull);
    expect(api.saved!.containsKey('weekly_sales_target_weight'), isFalse,
        reason: 'the week\'s team goal is the month\'s share, no setting');
  });

  testWidgets('the race board and its settings read in the dark theme, ranks in the medal tones', (tester) async {
    await _pump(tester, theme: DarkTheme.theme, settingsTab: false);
    expect(find.text('1,200'), findsWidgets, reason: 'points in the one number format');
    expect(find.bySemanticsLabel('تصدّر السباق 7 أشهر'), findsOneWidget);
    expect(find.text('4,200 من 5,000 نقطة'), findsOneWidget);
    expect(find.byKey(const Key('goal-line')), findsOneWidget, reason: 'alone on the board: a line');
    expect(find.byType(RaceRankRow), findsNWidgets(4), reason: 'one row for the race, the home card\'s');
    expect(find.text('84%'), findsOneWidget);
    expect(find.bySemanticsLabel('بلغ هدفه 2 مرات'), findsOneWidget);
    expectNoTextVanishesOnDark(tester);
    expectNoLightSurfaceOnDark(tester);
    await tester.tap(find.text('الإعدادات'));
    await tester.pumpAndSettle();
    expectNoTextVanishesOnDark(tester);
    expectNoLightSurfaceOnDark(tester);
  });
}
