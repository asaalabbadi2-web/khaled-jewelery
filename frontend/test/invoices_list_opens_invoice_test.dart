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

/// ADR-060 ف٢: «عرض الفاتورة» after a save opens the invoices list with that
/// invoice's sheet -- the one a tap on its row opens -- asked of the server
/// by its id.
void main() {
  testWidgets('the list opens the invoice it is given', (tester) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);

    final asked = <String>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AuthProvider()),
              ChangeNotifierProvider.value(value: settings),
            ],
            child: MaterialApp(
              theme: LightTheme.theme,
              home: const Directionality(
                textDirection: TextDirection.rtl,
                child: InvoicesListScreen(openInvoiceId: 412),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(asked, contains('/invoices/412'));
        expect(find.byType(DraggableScrollableSheet), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.textContaining('SELL-2026-412'),
          ),
          findsWidgets,
        );
      },
      () => MockClient((request) async {
        asked.add(request.url.path.replaceFirst(RegExp(r'^/api'), ''));
        if (request.url.path.endsWith('/invoices/412')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 412,
                'invoice_number': 'SELL-2026-412',
                'invoice_type': 'بيع',
                'customer_name': 'محمد العتيبي',
                'date': '2026-10-25T12:00:00',
                'total': 1000.0,
                'amount_paid': 1000.0,
                'status': 'paid',
                'items': [],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });
}
