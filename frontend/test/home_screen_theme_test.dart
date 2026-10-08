import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/home_screen_enhanced.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ثيم-٠: الشاشة الرئيسية تأخذ ألوانها من الثيم، فتظهر في الوضعين بلا استثناء،
/// ويتبع شريطها وقائمتها ألوان الوضع الذي هي فيه. الحدّ على الألوان المكتوبة فيها
/// صفر في `theme_raw_color_ratchet_test.dart`.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('the home screen draws in the $name theme, drawer included', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode({'main_karat': 21}),
      });
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SettingsProvider();
      await settings.loadSettings(fetchRemote: false);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuthProvider()),
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => QuickActionsProvider()),
            ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
          ],
          child: MaterialApp(
            theme: theme,
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: const HomeScreenEnhanced(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // The bar is the theme's: its title reads in the theme's bar color.
      final scheme = theme.colorScheme;
      final title = tester.widget<Text>(find.text('مجوهرات خالد').first);
      final titleColor = title.style!.color!;
      expect(
        titleColor,
        name == 'dark' ? scheme.primary : scheme.onPrimary,
      );

      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Drawer), findsOneWidget);
      expect(
        find.descendant(of: find.byType(Drawer), matching: find.text('الفواتير')),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
