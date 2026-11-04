import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/invoices_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/purchase_running_account.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// REPORTS ت3-2ج (ADR-083; the owner 4 Nov 2026): a supplier purchase shows
/// its running account's state, not its stored status -- stored «unpaid»
/// for 94 purchases the account had paid -- with why; one the supplier's
/// ledger does not hold says so.
Map<String, dynamic> _purchase(int id, Map<String, dynamic> account) => {
  'id': id,
  'invoice_number': 'BUY-2026-$id',
  'invoice_type': 'شراء',
  'supplier_id': 7,
  'supplier_name': 'شركة طيبة',
  'customer_name': 'شركة طيبة',
  'date': '2026-10-25T12:00:00',
  'total': 1000.0,
  'cash_obligation': 300.0,
  'amount_paid': 0.0,
  'status': 'unpaid',
  'is_posted': true,
  'items': [],
  'running_account': account,
};

void main() {
  test(
    'a purchase shows its running account; any other invoice its status',
    () {
      final paid = _purchase(1, {
        'state': 'paid',
        'basis': 'running_account',
        'shown': 'paid',
        'cash_original': 300.0,
        'cash_remaining': 0.0,
      });
      expect(shownInvoiceStatus(paid), 'paid');
      expect(runningAccountReason(paid), contains('الحساب الجاري'));
      expect(runningAccountCash(paid), (300.0, 0.0));
      final sale = {'invoice_type': 'بيع', 'status': 'unpaid'};
      expect(shownInvoiceStatus(sale), 'unpaid');
      expect(runningAccountReason(sale), isNull);
      expect(runningAccountCash(sale), isNull);
    expect(
      runningAccountCash(_purchase(2, {'state': 'not_on_account'})),
      (0.0, 0.0),
      reason: 'no debt on the supplier\'s ledger',
    );
    },
  );

  testWidgets('the list says the reading and why', (tester) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);

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
                child: InvoicesListScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('مدفوعة'), findsWidgets);
        expect(find.text('ليست على حساب المورد'), findsWidgets);
        expect(
          find.text('غير مدفوعة'),
          findsNothing,
          reason: 'the stored word',
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && (w.message ?? '').contains('الحساب الجاري'),
          ),
          findsWidgets,
        );
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/invoices')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'invoices': [
                  _purchase(1, {
                    'state': 'paid',
                    'basis': 'running_account',
                    'shown': 'paid',
                    'cash_original': 300.0,
                    'cash_remaining': 0.0,
                  }),
                  _purchase(2, {
                    'state': 'not_on_account',
                    'basis': null,
                    'shown': 'not_on_account',
                  }),
                ],
                'total': 2,
                'pages': 1,
                'current_page': 1,
                'per_page': 50,
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
