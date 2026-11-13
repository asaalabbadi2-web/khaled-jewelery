// The invoices list opens on «الكل» (the owner, 13 Nov 2026: «اضف تبويب الكل في
// قائمة الفواتير»): every kind together, no type asked of the server; a kind's
// own tab asks for its kind alone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/invoices_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('«الكل» first, asking no type; «بيع» asks for its own', (tester) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'auth_current_user': jsonEncode(AppUserModel.fromJson({
        'id': 3, 'username': 'manager', 'full_name': 'مدير تجريبي', 'role': 'manager', 'is_active': true,
        'is_admin': false, 'employee_id': 15, 'permissions': null, 'must_change_password': false,
        'effective_permissions': const ['invoices.view', 'invoices.view_others'],
      }).toStorageMap()),
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final auth = AuthProvider();
    await auth.init();

    final asked = <Map<String, String>>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            theme: LightTheme.theme,
            home: const Directionality(textDirection: TextDirection.rtl, child: InvoicesListScreen()),
          ),
        ));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final tabs = tester.widgetList<Tab>(find.byType(Tab)).toList();
        expect(tabs, isNotEmpty);
        expect(find.descendant(of: find.byWidget(tabs.first), matching: find.text('الكل')), findsOneWidget,
            reason: '«الكل» is the first tab');
        expect(asked.first.containsKey('invoice_types'), isFalse, reason: 'every kind: none asked');

        await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('بيع')).first);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(asked.last['invoice_types'], 'بيع');
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/invoices')) asked.add(request.url.queryParameters);
        final body = request.url.path.endsWith('/invoices')
            ? {'current_page': 1, 'pages': 1, 'per_page': 25, 'total': 0, 'meta': {}, 'invoices': []}
            : (request.url.path.contains('customers') || request.url.path.contains('suppliers') ? [] : {});
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
  });
}
