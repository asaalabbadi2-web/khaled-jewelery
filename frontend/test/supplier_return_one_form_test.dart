import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_return_invoice_screen.dart';
import 'package:frontend/screens/purchase_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_purchase_api.dart';

/// One form for a supplier's return, the purchase screen's (25 Oct 2026).
/// The general return form -- made for a customer, whose refund is cash --
/// refunded the gold's value too: a receipt of cash never received, and the
/// wages left unreversed. The side menu and the invoices list's «return» on a
/// purchase opened it.
/// The purchase being returned: 72.22 g at 12.75 a gram -- 920.81 in wages.
/// An invoice item's `wage` is the wage a gram, as the server keeps it.
class _OriginalApi extends FakePurchaseApi {
  @override
  Future<Map<String, dynamic>> getInvoiceById(int invoiceId) async => {
        'id': invoiceId, 'supplier_id': 1, 'branch_id': 1, 'invoice_type': 'شراء', 'vat_applied': false,
        'total_tax': 0,
        'items': [
          {'id': 4922, 'name': 'بناجر', 'karat': 21, 'weight': 72.22, 'wage': 12.75, 'quantity': 1},
        ],
      };
}

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  testWidgets('the general form asked for a supplier\'s return is the purchase screen, its original chosen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AddReturnInvoiceScreen(
            api: FakePurchaseApi(),
            returnType: 'مرتجع شراء (مورد)',
            prefilledOriginalInvoice: const {'id': 3470, 'supplier_id': 14},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final screen = tester.widget<PurchaseInvoiceScreen>(find.byType(PurchaseInvoiceScreen));
    expect(screen.supplierReturnMode, isTrue);
    expect((screen.originalInvoiceId, screen.supplierId), (3470, 14));
  });

  test('no entrance opens the general form for a supplier\'s return', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      for (final m in RegExp(r'AddReturnInvoiceScreen\(').allMatches(text)) {
        final call = text.substring(m.start, (m.start + 260).clamp(0, text.length));
        if (call.contains("'مرتجع شراء (مورد)'")) offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });

  testWidgets('a return of a purchase takes its wage a gram, not the wage a gram as the line\'s wage',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PurchaseInvoiceScreen(apiService: _OriginalApi(), supplierReturnMode: true, originalInvoiceId: 3470),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('920.81', findRichText: true), findsWidgets, reason: '72.22 g × 12.75');
  });
}
