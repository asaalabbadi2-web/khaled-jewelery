// The sign-in in the dark (the owner, 13 Nov 2026: «تسجيل الدخول في الوضع الداكن
// الوانها مزعجه»): its background was a sheet of the bright gold the dark
// theme lights with, and the version under the card dark on it. Dark, the
// background is the night's own surface and what stands on it reads (4.5:1);
// light, it is as it was -- the theme's gold deepening.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_login_api.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Future<void> _open(WidgetTester tester, ThemeData theme) async {
  SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: AuthProvider(api: () => FakeLoginApi(const []))),
      ChangeNotifierProvider.value(value: settings),
    ],
    child: MaterialApp(
      theme: theme,
      home: Directionality(textDirection: TextDirection.rtl, child: LoginScreen(pingServer: () async => true)),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

List<Color> _background(WidgetTester tester) =>
    ((tester.widget<Container>(find.byKey(const Key('login-background'))).decoration! as BoxDecoration).gradient!
            as LinearGradient)
        .colors;

void main() {
  testWidgets('dark: a dark background, and the version reads on it', (tester) async {
    await _open(tester, DarkTheme.theme);
    final colors = _background(tester);
    for (final c in colors) {
      expect(c.computeLuminance(), lessThan(0.05), reason: 'not the bright gold');
    }
    final version = tester.widget<Text>(find.byKey(const Key('login-version'))).style!.color!;
    final on = Color.alphaBlend(version, colors.last);
    expect(_contrast(on, colors.last), greaterThanOrEqualTo(4.5));
  });

  testWidgets('light: the theme\'s gold, as it was', (tester) async {
    await _open(tester, LightTheme.theme);
    expect(_background(tester).first, LightTheme.theme.colorScheme.primary);
  });
}
