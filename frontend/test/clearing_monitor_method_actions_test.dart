import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/clearing_monitor_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a payment method asks of its clearing box -- a deposit confirmed by
/// what reached the bank (ADR-100), its commissions' monthly tax invoices
/// (ADR-101) -- is offered on the wide screen as on the narrow one: the wide
/// table's box showed neither (the owner, 28 Nov 2026: «الخيار يظهر في
/// الشاشات الصغيره فقط»). A method with plans has no one rate: its commission
/// is said «بالخطط», not «0.0%».
Map<String, dynamic> _box(int id, String name) => {
  'id': id,
  'name': name,
  'safe_type': 'clearing',
  'account_id': 700 + id,
  'is_active': true,
  'balance': {'cash': 0.0},
};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  /// Tamara (box 33) asks both; Mada (box 32) asks neither.
  Future<void> open(WidgetTester tester, Size size, {required Future<void> Function() then}) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    await http.runWithClient(
      () async {
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(theme: LightTheme.theme, home: const ClearingMonitorScreen()),
        ));
        await tester.pumpAndSettle();
        await then();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/safe-boxes')) return json([_box(32, 'مدى'), _box(33, 'تمارا')]);
        if (path.endsWith('/payment-methods/active')) {
          return json([
            {'id': 10, 'name': 'مدى', 'default_safe_box_id': 32, 'commission_rate': 0.8},
            {
              'id': 13,
              'name': 'تمارا',
              'default_safe_box_id': 33,
              'commission_rate': 0,
              'plans': [
                {'label': '4 دفعات', 'rate': 5.99},
                {'label': '6 دفعات', 'rate': 6.99},
              ],
              'deposit_confirmation_required': true,
              'tax_invoice_from': '2026-10',
            },
          ]);
        }
        if (path.endsWith('/pending-transactions')) {
          return json({'due_amount': 0.0, 'transactions': []});
        }
        return json({});
      }),
    );
  }

  for (final (name, size) in [('wide', const Size(1400, 1000)), ('narrow', const Size(700, 2400))]) {
    testWidgets('$name: a method that asks a deposit confirmation and tax invoices offers both', (tester) async {
      await open(tester, size, then: () async {
        // The wide table shows one box beside it; a narrow card opens on its
        // tap. Either way: choose Tamara's.
        await tester.tap(find.text('تمارا').first);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('deposit-confirm-open-33')), findsOneWidget);
        expect(find.byKey(const Key('tax-invoices-open-33')), findsOneWidget);
        expect(find.byKey(const Key('deposit-confirm-open-32')), findsNothing, reason: 'Mada asks neither');
        expect(find.textContaining('بالخطط'), findsWidgets, reason: 'plans, not «0.0%»');
        expect(find.text('عمولة: 0.0%'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
