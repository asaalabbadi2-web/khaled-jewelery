// The home bar's chart follows the main karat (the owner, 13 Nov 2026: «الرسم
// ثابت لعيار ٢١ وليس للعيار الاساسي» -- the main karat became 24 and the chart
// stayed 21's: the home reloaded the 24 hours every 15 minutes only).
//
// Opened at 21; the settings' main karat becomes 24: the 24 hours are asked
// again at once, and the chart's line is 24's. Never another karat's line in
// between: an answer for 21 while the karat is 24 shows the ounce's alone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/home_screen_enhanced.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _held = ['gold_price.view', 'gold_price.update', 'invoices.view', 'customers.view', 'items.view'];

int _karat = 21;          // the server's main karat: the settings'
int _asked24h = 0;

Map<String, dynamic> _price() => {
      'currency': 'ر.س', 'main_karat': _karat, 'price_usd_per_oz': 4105.2, 'date': DateTime.now().toUtc().toIso8601String(),
      'prices_per_gram': {
        for (final k in const [18, 21, 22, 24]) '$k': {'sell': 400.0 + k, 'buy': 390.0 + k},
      },
      'opening_prices_per_gram': {
        for (final k in const [18, 21, 22, 24]) '$k': {'sell': 399.0 + k},
      },
      'market': {'open': true, 'unavailable': false},
    };

Map<String, dynamic> _day() {
  _asked24h++;
  final now = DateTime.now().toUtc();
  return {
    'main_karat': _karat, 'high_main_karat': 430.0, 'low_main_karat': 420.0,
    'high_usd_per_oz': 4110.0, 'low_usd_per_oz': 4090.0,
    'points': [
      for (var i = 0; i < 5; i++)
        {
          'timestamp': now.subtract(Duration(hours: 6 * (4 - i))).toIso8601String(),
          'price_usd_per_oz': 4090.0 + i * 4,
          'price_main_karat': 400.0 + _karat + i * 0.5,
        },
    ],
  };
}

Object _answer(String path) {
  if (path.endsWith('/gold_price/24h')) return _day();
  if (path.endsWith('/gold_price')) return _price();
  if (path.contains('customers') || path.contains('items') || path.contains('safe')) return [];
  return {};
}

String? _chartLine(WidgetTester tester) {
  final first = find.byKey(const Key('gold-chart-series-0'));
  if (first.evaluate().isEmpty) return null;
  return tester.widget<Text>(find.descendant(of: first, matching: find.byType(Text))).data;
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

  testWidgets('the main karat becomes 24: the chart is asked again at once, and its line is 24\'s', (tester) async {
    _karat = 21;
    _asked24h = 0;
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'auth_current_user': jsonEncode(AppUserModel.fromJson({
        'id': 3, 'username': 'saleh', 'full_name': 'صالح', 'role': 'manager', 'is_active': true, 'is_admin': false,
        'employee_id': 15, 'effective_permissions': _held, 'permissions': null, 'must_change_password': false,
      }).toStorageMap()),
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final auth = AuthProvider();
    await auth.init();
    final errors = <String>[];
    final before = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
    try {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>.value(value: auth),
              ChangeNotifierProvider.value(value: settings),
              ChangeNotifierProvider(create: (_) => ThemeProvider()),
              ChangeNotifierProvider(create: (_) => QuickActionsProvider()),
              ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
            ],
            child: MaterialApp(theme: LightTheme.theme, home: HomeScreenEnhanced(onToggleLocale: () {})),
          ));
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(_chartLine(tester), 'عيار 21');
          final asked = _asked24h;

          // The owner sets the main karat to 24.
          _karat = 24;
          final prefs = await SharedPreferences.getInstance();      // the sign-in stays
          await prefs.setString('app_settings', jsonEncode({'main_karat': 24}));
          await settings.loadSettings(fetchRemote: false);
          await tester.pump();
          expect(_chartLine(tester), isNot('عيار 21'), reason: "never 21's line while the karat is 24");
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(_asked24h, greaterThan(asked), reason: 'asked again at once, not at the next quarter hour');
          expect(_chartLine(tester), 'عيار 24');
        },
        () => MockClient((request) async => http.Response.bytes(
              utf8.encode(jsonEncode(_answer(request.url.path))),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      );
    } finally {
      FlutterError.onError = before;
    }
    expect(errors.where((e) => e.contains('overflowed')), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
