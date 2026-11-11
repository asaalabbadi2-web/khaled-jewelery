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

/// The return audit, 11 Nov 2026: an invoice opened from the list never said
/// it had been returned, nor a return what it returned -- the server had them
/// and no screen asked. The invoice's details carry them; the sheet says them.
class _Accountant extends AuthProvider {
  @override
  bool hasPermission(String key) => true;
}

Future<void> _open(WidgetTester tester, int id, Map<String, dynamic> details) async {
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = const Size(1440, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await http.runWithClient(
    () async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(create: (_) => _Accountant()),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            theme: LightTheme.theme,
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: InvoicesListScreen(openInvoiceId: id),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    },
    () => MockClient((request) async {
      if (request.url.path.endsWith('/invoices/$id')) {
        return http.Response.bytes(utf8.encode(jsonEncode(details)), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response(jsonEncode({'invoices': [], 'items': []}), 200,
          headers: {'content-type': 'application/json'});
    }),
  );
}

void main() {
  testWidgets('a sale says its returns, the rejected one so said', (tester) async {
    await _open(tester, 3771, {
      'id': 3771, 'invoice_number': 'SELL-2026-1982', 'invoice_type': 'بيع', 'customer_name': 'عميل نقدي',
      'date': '2026-11-08T12:00:00', 'total': 73700.0, 'amount_paid': 73700.0, 'status': 'paid',
      'is_posted': true, 'items': [], 'payments': [], 'original_invoice': null,
      'returns': [
        {'id': 3791, 'invoice_number': 'RET-2026-0017', 'date': '2026-11-11T10:00:00', 'total': 6500.0,
         'total_weight': 15.8, 'status': 'paid'},
        {'id': 3792, 'invoice_number': 'RET-2026-0018', 'date': '2026-11-11T11:00:00', 'total': 100.0,
         'total_weight': 0.5, 'status': 'rejected'},
      ],
    });
    final returns = find.byKey(const Key('invoice-returns'));
    expect(returns, findsOneWidget);
    expect(find.descendant(of: returns, matching: find.textContaining('RET-2026-0017 · 2026-11-11')), findsOneWidget);
    expect(find.descendant(of: returns, matching: find.text('15.800 جم · 6,500.00')), findsOneWidget);
    expect(find.descendant(of: returns, matching: find.textContaining('مرفوض')), findsOneWidget);
  });

  testWidgets('a return says its original, a sale with none says nothing', (tester) async {
    await _open(tester, 3791, {
      'id': 3791, 'invoice_number': 'RET-2026-0017', 'invoice_type': 'مرتجع بيع', 'customer_name': 'عميل نقدي',
      'date': '2026-11-11T10:00:00', 'total': 6500.0, 'amount_paid': 6500.0, 'status': 'paid',
      'is_posted': true, 'items': [], 'payments': [], 'returns': [],
      'original_invoice': {'id': 3771, 'invoice_number': 'SELL-2026-1982'},
    });
    expect(find.text('مرتجع للفاتورة SELL-2026-1982'), findsOneWidget);
    expect(find.byKey(const Key('invoice-returns')), findsNothing);
  });
}
