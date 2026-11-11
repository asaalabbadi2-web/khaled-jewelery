// The home screen fits the shop's devices (the owner, 11 Nov 2026: «شكل الشاشة
// الرئيسية في الشاشات الصغيرة، هل هو مثالي؟»).
//
// Drawn as the seller and as the manager -- the manager with both of the
// bar's signs up, «المجدول متوقف» and «بانتظار الإجراء» -- at an iPhone, an
// iPhone SE and an iPad mini: nothing overflows, the menu and the search stay
// on the bar, the bottom bar holds five at most on a phone, and the quick
// actions are three a row. On the 10 Nov copy the manager's bar ran 19 px past
// an iPhone (34 past an SE) and pushed the menu off it.

import 'dart:convert';
import 'dart:io';

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

import 'support/shots.dart';

const _devices = <String, Size>{
  'iPhone': Size(390, 844),
  'iPhone SE': Size(375, 667),
  'iPad mini': Size(744, 1133),
};

const _seller = [
  'customers.create', 'customers.view', 'gold_price.update', 'gold_price.view', 'inventory.view',
  'invoices.create', 'invoices.edit', 'invoices.view', 'items.view', 'print.invoices', 'safe_boxes.view',
  'suppliers.view',
];

const _manager = [
  ..._seller, 'accounts.view', 'dashboard.admin', 'invoices.approve', 'invoices.return', 'invoices.supplier',
  'invoices.view_others', 'invoices.edit_others', 'journal.view', 'opening.enter', 'reports.financial',
  'reports.sales', 'safe_boxes.transfer', 'vouchers.view', 'employees.view', 'employees.payroll',
  'employees.bonuses',
];

Map<String, dynamic> _user(String role, List<String> held) => {
      'id': role == 'manager' ? 3 : 7, 'username': role == 'manager' ? 'saleh' : 'yousif',
      'full_name': role == 'manager' ? 'صالح العبادي' : 'يوسف الشعبي', 'role': role, 'is_active': true,
      'is_admin': false, 'employee_id': role == 'manager' ? 15 : 18, 'effective_permissions': held,
      'permissions': null, 'must_change_password': false,
    };

const _prices = {'buy': 436.25, 'sell': 440.65};
final _goldPrice = {
  'currency': 'ر.س', 'main_karat': 21, 'price_usd_per_oz': 4140.655, 'price_main_karat': 440.65,
  'price_24k': 504.52, 'date': '2026-11-09T22:02:35Z', 'buy_price_ratio': 0.99,
  'prices_per_gram': {'18': _prices, '21': _prices, '22': _prices, '24': _prices},
  'market': {'open': true, 'unavailable': false},
};

Object _answer(String path, bool manager) {
  if (path.endsWith('/public/gold_price')) return _goldPrice;
  if (path.endsWith('/pending-actions')) {
    return manager
        ? {'total_pending_invoices': 3, 'total_pending_reservations': 0, 'total_system_alerts': 1,
           'pending_invoices': [], 'pending_reservations': [], 'system_alerts': []}
        : {'total_pending_invoices': 0, 'total_pending_reservations': 0, 'total_system_alerts': 0};
  }
  if (path.contains('customers') || path.contains('items') || path.contains('safe')) return [];
  return {};
}

/// The screen opened; what overflowed, said by the framework.
Future<List<String>> _open(WidgetTester tester, Size size, {required bool manager}) async {
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'auth_current_user': jsonEncode(
        AppUserModel.fromJson(_user(manager ? 'manager' : 'employee', manager ? _manager : _seller))
            .toStorageMap()),
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final auth = AuthProvider();
  await auth.init();
  final found = <String>[];
  final before = FlutterError.onError;
  FlutterError.onError = (details) {
    found.add(details.exceptionAsString().split('\n').first);
  };
  try {
  await http.runWithClient(
    () async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => QuickActionsProvider()),
            ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: LightTheme.theme,
            home: HomeScreenEnhanced(onToggleLocale: () {}),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
    () => MockClient((request) async => http.Response.bytes(
          utf8.encode(jsonEncode(_answer(request.url.path, manager))),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        )),
  );
  } finally {
    FlutterError.onError = before;
  }
  return found;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
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
    if (shotDir.isNotEmpty) {
      final icons = await File(
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons)))).load();
    }
  });

  for (final manager in [false, true]) {
    final who = manager ? 'the manager, both signs up' : 'the seller';
    for (final device in _devices.entries) {
      testWidgets('the home screen fits an ${device.key}, as $who', (tester) async {
        final overflows = await _open(tester, device.value, manager: manager);
        expect(overflows, isEmpty, reason: '$who on ${device.key}');
        // The menu stays on the bar, whatever its signs.
        final menu = find.byIcon(Icons.menu_rounded);
        expect(menu, findsOneWidget);
        final box = tester.getRect(menu);
        expect(box.left >= 0 && box.right <= device.value.width, isTrue, reason: 'the menu on the screen: $box');
        await shot(tester, 'home_${manager ? 'manager' : 'seller'}_${device.key.replaceAll(' ', '_')}');
        await _close(tester);
      });
    }
  }

  testWidgets('on a phone the bottom bar holds five, settings in the account menu', (tester) async {
    await _open(tester, _devices['iPhone']!, manager: true);
    expect(find.text('لوحة المدير'), findsWidgets);
    expect(find.text('الإعدادات'), findsNothing, reason: 'not a sixth tab');
    await tester.tap(find.byKey(const Key('user-menu')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('user-menu-settings')), findsOneWidget);
    expect(find.byKey(const Key('user-menu-theme')), findsOneWidget);
    expect(find.byKey(const Key('user-menu-locale')), findsOneWidget);
    await _close(tester);
  });

  testWidgets('on an iPad mini the bar keeps the theme and the language, and six tabs', (tester) async {
    await _open(tester, _devices['iPad mini']!, manager: true);
    expect(find.byIcon(Icons.language), findsOneWidget);
    expect(find.text('الإعدادات'), findsWidgets);
    await _close(tester);
  });

  testWidgets('the quick actions are three a row on a phone', (tester) async {
    await _open(tester, _devices['iPhone']!, manager: false);
    // The first group's grid: three shown, the rest behind «المزيد» -- not two
    // with the third column empty.
    final grid = tester.widget<GridView>(find.byType(GridView).first);
    final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect((grid.childrenDelegate as SliverChildBuilderDelegate).childCount, 3);
    await _close(tester);
  });
}
