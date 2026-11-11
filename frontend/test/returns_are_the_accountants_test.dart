import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/invoices_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner, 11 Nov 2026: «الموظف ليس له صلاحية عمل مرتجع حتى لفواتيره هو؛
/// المرتجع بصلاحيات المحاسب والمدير ومن هو أعلى». The server asks
/// `invoices.return`; the app does not offer a return to whoever does not
/// hold it -- the seller met «إنشاء مرتجع» and was refused.
class _User extends AuthProvider {
  _User(this.held);
  final Set<String> held;
  @override
  bool hasPermission(String key) => held.contains(key);
}

const _seller = {'invoices.view', 'invoices.create', 'invoices.edit'};
const _accountant = {..._seller, 'invoices.view_others', 'invoices.supplier', 'invoices.return'};

Future<void> _openSale(WidgetTester tester, Set<String> held) async {
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = const Size(1440, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await http.runWithClient(
    () async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(create: (_) => _User(held)),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            theme: LightTheme.theme,
            home: const Directionality(
              textDirection: TextDirection.rtl,
              child: InvoicesListScreen(openInvoiceId: 3779),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    },
    () => MockClient((request) async {
      if (request.url.path.endsWith('/invoices/3779')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'id': 3779, 'invoice_number': 'SELL-2026-1990', 'invoice_type': 'بيع', 'customer_name': 'عميل نقدي',
            'date': '2026-11-09T12:00:00', 'total': 12600.0, 'amount_paid': 12600.0, 'status': 'paid',
            'is_posted': true, 'items': [], 'payments': [],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(jsonEncode({'invoices': [], 'items': []}), 200,
          headers: {'content-type': 'application/json'});
    }),
  );
}

void main() {
  testWidgets('a seller is not offered a return, not even of their own sale', (tester) async {
    await _openSale(tester, _seller);
    expect(find.text('إنشاء مرتجع'), findsNothing);
  });

  testWidgets('the accountant is offered it', (tester) async {
    await _openSale(tester, _accountant);
    expect(find.text('إنشاء مرتجع'), findsOneWidget);
  });
}
