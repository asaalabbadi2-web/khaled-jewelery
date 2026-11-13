// An invoice card says its weight for what it is (the owner, 13 Nov 2026:
// «طريقة عرض الوزن في البطائق اجعله افضل»): the server's weight is in the main
// karat -- «وزن: X جم» beside «عيار: 18» read as 18's grams. An 18 invoice: its
// karat, and «≈ X جم بعيار 21» under it. A main-karat invoice: one chip, its
// grams. Made-up invoices.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/invoices_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _invoice(int id, String karat, double mainKaratGrams) => {
      'id': id, 'invoice_number': 'SELL-2026-0000$id', 'invoice_type': 'بيع', 'date': '2026-11-1${id}T10:30:00',
      'customer_name': 'عميل $id', 'total': 9000.0, 'amount_paid': 9000.0, 'is_posted': true, 'status': 'paid',
      'karat': karat, 'total_weight_main_karat': mainKaratGrams, 'items': [], 'payments': [], 'karat_lines': [],
    };

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

  testWidgets('an 18 invoice: its karat, and its weight said in the main karat; a 21 one: one chip', (tester) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'auth_current_user': jsonEncode(AppUserModel.fromJson({
        'id': 3, 'username': 'manager', 'full_name': 'مدير', 'role': 'manager', 'is_active': true, 'is_admin': false,
        'employee_id': 15, 'permissions': null, 'must_change_password': false,
        'effective_permissions': const ['invoices.view', 'invoices.view_others'],
      }).toStorageMap()),
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final auth = AuthProvider();
    await auth.init();
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
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      },
      () => MockClient((request) async {
        final body = request.url.path.endsWith('/invoices')
            ? {'current_page': 1, 'pages': 1, 'per_page': 25, 'total': 2, 'meta': {},
               'invoices': [_invoice(1, '18', 22.071), _invoice(2, '21', 25.75)]}
            : (request.url.path.contains('customers') || request.url.path.contains('suppliers') ? [] : {});
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    expect(tester.takeException(), isNull);

    final eighteen = find.byKey(const ValueKey('invoice-weight-1'));
    expect(eighteen, findsOneWidget);
    expect(find.text('عيار: 18'), findsOneWidget, reason: 'its karat');
    expect(find.descendant(of: eighteen, matching: find.byKey(const Key('karat-weights-equivalent'))), findsOneWidget,
        reason: 'its weight said as the main karat\'s');
    expect(find.descendant(of: eighteen, matching: find.textContaining('بعيار 21', findRichText: true)), findsOneWidget);

    final main = find.byKey(const ValueKey('invoice-weight-2'));
    expect(find.descendant(of: main, matching: find.text('عيار 21')), findsOneWidget);
    expect(find.descendant(of: main, matching: find.text('25.750')), findsOneWidget);
    expect(find.text('عيار: 21'), findsNothing, reason: 'one chip, not its karat twice');
  });
}
