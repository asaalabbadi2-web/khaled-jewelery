import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/home_screen_enhanced.dart';
import 'package:frontend/screens/reports/admin_dashboard_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DASH-3: the manager's dashboard is a fixed item of the side menu, under
/// «الرئيسية» -- for the manager alone (the owner, 30 Oct 2026: «لوحة تحكم
/// المدير لم تظهر في القائمة الجانبية»; it was in the bottom bar only).
class _Holder extends AuthProvider {
  _Holder(this.dashboard);

  final bool dashboard;
  @override
  String get username => 'u';
  @override
  bool hasPermission(String key) => key == 'dashboard.admin' ? dashboard : true;
}

void main() {
  Future<void> openDrawer(WidgetTester tester, {required bool dashboard}) async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
    SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => _Holder(dashboard)),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => QuickActionsProvider()),
        ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: const Directionality(textDirection: TextDirection.rtl, child: HomeScreenEnhanced()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.menu_rounded));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));     // the menu's opening, frame by frame
    }
  }

  testWidgets('the manager finds the dashboard under «الرئيسية» in the side menu', (tester) async {
    await openDrawer(tester, dashboard: true);
    final item = find.byKey(const ValueKey('drawer-fixed-dashboard'));
    expect(item, findsOneWidget);
    expect(find.descendant(of: item, matching: find.text('لوحة تحكم المدير')), findsOneWidget);
    final home = tester.getTopLeft(find.byKey(const ValueKey('drawer-fixed-home')));
    expect(tester.getTopLeft(item).dy, greaterThan(home.dy), reason: 'under «الرئيسية»');
  });

  testWidgets('whoever does not hold it does not find it', (tester) async {
    await openDrawer(tester, dashboard: false);
    expect(find.byKey(const ValueKey('drawer-fixed-home')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-fixed-dashboard')), findsNothing);
  });

  // The owner, 31 Oct 2026: «زر العودة لا يقوم بدور صحيح أثناء الدخول من القائمة
  // الجانبية والسفلية» -- opened from the menu it is a tab: back is the home tab.
  testWidgets('opened from the menu, its back is the home tab', (tester) async {
    await openDrawer(tester, dashboard: true);
    await tester.tap(find.byKey(const ValueKey('drawer-fixed-dashboard')));
    await tester.pump(const Duration(milliseconds: 600));
    final dashboard = tester.widget<AdminDashboardScreen>(find.byType(AdminDashboardScreen));
    expect(dashboard.onBack, isNotNull, reason: 'a tab: nothing behind it to pop to');
    dashboard.onBack!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AdminDashboardScreen), findsNothing, reason: 'the home tab again');
  });
}
