// The invoices fit the shop's devices (the owner, 9 Nov 2026: «هاتف ايفون
// وتابلت بحجم اي باد ميني»).
//
// Each invoice the shop writes on them -- a sale, a scrap sale, a scrap
// purchase, a supplier's purchase -- opened at an iPhone (390×844), the
// smallest one (iPhone SE, 375×667) and an iPad mini upright (744×1133),
// with a line written and every section scrolled into sight: nothing may
// overflow. A screen that did not fit said so only as a striped band at its
// edge (the sale 39 px, the purchase 62 px off an iPhone's right, 9 Nov).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_return_invoice_screen.dart';
import 'package:frontend/widgets/return_reason_input.dart';
import 'package:frontend/screens/purchase_invoice_screen.dart';
import 'package:frontend/screens/sales_invoice_screen_v2.dart';
import 'package:frontend/screens/scrap_purchase_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_purchase_api.dart';
import 'support/fake_sales_api.dart';

const devices = <String, Size>{
  'iPhone': Size(390, 844),
  'iPhone SE': Size(375, 667),
  'iPad mini': Size(744, 1133),
};

final _saleDraft = {
  'version': 1,
  'branch_id': 1,
  'customer_id': null,
  'custom_amount': '',
  'selected_payment_method_id': 1,
  'payments': [
    {
      'payment_method_id': 1, 'payment_method_name': 'نقداً', 'amount': 1000.0, 'commission_rate': 0,
      'commission_amount': 0, 'commission_vat': 0, 'net_amount': 1000.0, 'settlement_days': 0,
    },
  ],
  'items': [
    {
      'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'wage': 0, 'count': 1, 'tax_rate': 0,
      'has_manual_total': true, 'manual_total': 1000.0,
    },
  ],
};

final _purchaseDraft = {
  'version': 1,
  'supplier_id': 1,
  'branch_id': 1,
  'settlement_mode': 'credit',
  'cash_paid': '0.00',
  'selected_payment_method_id': 1,
  'selected_gold_paid_karat': 21,
  'gold_settlements': [],
  'karat_lines': [],
  'manual_pricing': false,
  'inline_items': [
    {
      'name': 'خاتم', 'karat': 21, 'weight_grams': 12.5, 'wage_per_gram': 18, 'entry_type': 'category',
      'category': 'سلسال 21', 'category_id': 40,
    },
  ],
};

typedef _Screen = Widget Function();

/// A sale returned (the owner, 10 Nov 2026: «المرتجع في الأخير»).
final _returned = <String, dynamic>{
  'id': 10, 'invoice_type': 'بيع', 'customer_id': 8, 'branch_id': 1, 'total': 1000.0, 'total_weight': 2.0,
  'total_tax': 0.0,
  'items': [
    {'id': 100, 'name': 'سلسال', 'karat': 21, 'weight': 2.0, 'quantity': 1, 'price': 1000.0, 'net': 1000.0,
     'tax': 0.0, 'wage': 0.0},
  ],
};

Widget _returnScreen() => AddReturnInvoiceScreen(
      api: FakeSalesApi(invoices: {10: _returned}),
      returnType: 'مرتجع بيع',
      prefilledOriginalInvoice: _returned,
    );

final screens = <String, (Map<String, Object>, _Screen)>{
  'sale': (
    {'yasargold_sales_invoice_complete_later_v2': jsonEncode(_saleDraft)},
    () => SalesInvoiceScreenV2(items: const [], customers: const [], apiService: FakeSalesApi()),
  ),
  'scrap sale': (
    const {},
    () => SalesInvoiceScreenV2(items: const [], customers: const [], apiService: FakeSalesApi(), scrap: true),
  ),
  'scrap purchase': (
    const {},
    () => ScrapPurchaseInvoiceScreen(customers: const [], apiService: FakeSalesApi()),
  ),
  'supplier purchase': (
    {'yasargold_purchase_invoice_complete_later': jsonEncode(_purchaseDraft)},
    () => PurchaseInvoiceScreen(apiService: FakePurchaseApi()),
  ),
  'whole return': (const {}, _returnScreen),
};

/// What did not fit, said by the framework -- one line each.
List<String> _overflows(WidgetTester tester) => [
      for (Object? e = tester.takeException(); e != null; e = tester.takeException())
        e.toString().split("\n").where((l) => l.contains("lib/") || l.contains("overflowed")).take(3).join(" | "),
    ];

Future<List<String>> _open(WidgetTester tester, Size size, Map<String, Object> prefs, _Screen screen) async {
  SharedPreferences.setMockInitialValues({
    'app_settings': jsonEncode({'main_karat': 21, 'sales_vat_enabled': false}),
    ...prefs,
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Directionality(textDirection: TextDirection.rtl, child: screen()),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  final found = _overflows(tester);
  if (find.text('استعادة').evaluate().isNotEmpty) {
    await tester.tap(find.text('استعادة'));
    await tester.pumpAndSettle();
  }
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  found.addAll(_overflows(tester));
  // every section, scrolled into sight
  final scrollable = find.byType(Scrollable).first;
  for (var page = 0; page < 8; page++) {
    await tester.drag(scrollable, const Offset(0, -600), warnIfMissed: false);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    found.addAll(_overflows(tester));
  }
  return found;
}

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  for (final screen in screens.entries) {
    for (final device in devices.entries) {
      testWidgets('the ${screen.key} fits an ${device.key}', (tester) async {
        final (prefs, build) = screen.value;
        final overflows = await _open(tester, device.value, prefs, build);
        expect(overflows, isEmpty, reason: '${screen.key} on ${device.key}');
      });
    }
  }

  // A return of part of a sale is a wizard: every step, as the employee
  // walks it. Its payment step ran 54 px off an iPhone, and its lines sat in
  // a box of 320 px that cut them (10 Nov 2026).
  for (final device in devices.entries) {
    testWidgets('a partial return fits an ${device.key}, every step', (tester) async {
      final found = await _open(tester, device.value, const {}, _returnScreen);
      Future<void> step(Future<void> Function() act) async {
        await act();
        await tester.pumpAndSettle();
        found.addAll(_overflows(tester));
        final scrollable = find.byType(Scrollable).first;
        for (var page = 0; page < 6; page++) {
          await tester.drag(scrollable, const Offset(0, -500), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 100));
          found.addAll(_overflows(tester));
        }
      }

      Future<void> tapText(String text) async {
        await tester.ensureVisible(find.text(text).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(text).hitTestable().last);
      }

      await step(() => tapText('إرجاع جزء فقط'));
      await step(() => tester.enterText(find.byKey(const ValueKey('amount-100-0')), '1000'));
      expect(find.text('اختر الأصناف المرتجعة'), findsOneWidget);
      expect(find.textContaining('الإجمالي', findRichText: true), findsWidgets, reason: 'the line\'s figures, not cut');
      await step(() => tapText('التالي'));
      await step(() async {
        await tester.enterText(find.descendant(of: find.byType(ReturnReasonInput), matching: find.byType(TextFormField)), 'عيب في الصنع');
        await tapText('التالي');
      });
      expect(find.textContaining('القيمة المرجعية'), findsOneWidget, reason: 'at the payment step');
      await step(() async {
        await tapText('وسيلة الدفع');
        await tester.pumpAndSettle();
        await tester.tap(find.text('نقداً').last);
        await tester.pumpAndSettle();
        await tapText('التالي');
      });
      expect(found, isEmpty, reason: device.key);
    });
  }
}
