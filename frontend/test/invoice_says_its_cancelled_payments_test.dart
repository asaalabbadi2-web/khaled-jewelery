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

/// The owner, 31 Oct 2026: «هل إلغاء سند دفعة يحدّث الدفعات في عرض الفاتورة؟»
/// -- 1785's cancelled payments were listed as standing. A cancelled payment
/// stays, its history, said so -- «ملغاة» and its voucher, struck through --
/// and is not offered for correction; the server says which (the payment
/// state's own rule).
class _Manager extends AuthProvider {
  @override
  bool get isManager => true;
  @override
  bool hasPermission(String key) => true;
}

void main() {
  testWidgets('a cancelled payment is said cancelled, and not corrected', (tester) async {
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
              ChangeNotifierProvider<AuthProvider>(create: (_) => _Manager()),
              ChangeNotifierProvider.value(value: settings),
            ],
            child: MaterialApp(
              theme: LightTheme.theme,
              home: const Directionality(
                textDirection: TextDirection.rtl,
                child: InvoicesListScreen(openInvoiceId: 3588),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final cancelled = find.byKey(const ValueKey('invoice-payment-3932'));
        final standing = find.byKey(const ValueKey('invoice-payment-3949'));
        expect(cancelled, findsOneWidget);
        expect(find.descendant(of: cancelled, matching: find.text('ملغاة · RV-2026-02155')), findsOneWidget);
        expect(find.descendant(of: cancelled, matching: find.byTooltip('تصحيح وسيلة الدفع')), findsNothing);
        expect(find.descendant(of: standing, matching: find.byKey(const Key('invoice-payment-cancelled'))),
            findsNothing);
        expect(find.descendant(of: standing, matching: find.byTooltip('تصحيح وسيلة الدفع')), findsOneWidget);
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/invoices/3588')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'id': 3588,
              'invoice_number': 'SELL-2026-1794',
              'invoice_type': 'بيع',
              'customer_name': 'عميل نقدي',
              'date': '2026-10-30T21:32:06',
              'total': 7100.0,
              'amount_paid': 7100.0,
              'total_payments_amount': 7100.0,
              'status': 'paid',
              'items': [],
              'payments': [
                {'id': 3932, 'payment_method_id': 10, 'payment_method_name': 'مدى', 'amount': 7100.0,
                 'voucher_number': 'RV-2026-02155', 'cancelled': true},
                {'id': 3949, 'payment_method_id': 10, 'payment_method_name': 'مدى', 'amount': 7100.0,
                 'voucher_number': 'RV-2026-02168', 'cancelled': false},
              ],
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'invoices': [], 'items': []}), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
  });
}
