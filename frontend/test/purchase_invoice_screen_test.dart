import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/purchase_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_purchase_api.dart';

/// PURCHASE-UX-1 (the owner, 6 Oct 2026): the purchase invoice screen says
/// «ready» only when the server would take the invoice; otherwise it names the
/// reason and sends nothing. One save at a time, Ctrl+S, and leaving with
/// work in it asks first.
void main() {
  // The app's own face: layout is measured as it is drawn, not in Ahem.
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  const draftKey = 'yasargold_purchase_invoice_complete_later';

  Map<String, dynamic> draft({
    int? supplierId = 1,
    String settlement = 'credit',
    List<Map<String, dynamic>> karatLines = const [],
    List<Map<String, dynamic>> goldSettlements = const [],
  }) => {
    'version': 1,
    'supplier_id': supplierId,
    'branch_id': 1,
    'settlement_mode': settlement,
    'cash_paid': '0.00',
    'selected_payment_method_id': 1,
    'selected_gold_paid_karat': 21,
    'gold_settlements': goldSettlements,
    'karat_lines': karatLines,
    'inline_items': [
      {
        'name': 'خاتم',
        'karat': 21,
        'weight_grams': 12.5,
        'wage_per_gram': 18,
        'entry_type': 'item',
      },
    ],
  };

  /// Opens the screen from a home route on a wide window, restoring [saved]
  /// as the user's «complete later» invoice.
  Future<void> open(
    WidgetTester tester, {
    required FakePurchaseApi api,
    Map<String, dynamic>? saved,
    Map<String, dynamic>? appSettings,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (saved != null) draftKey: jsonEncode(saved),
      if (appSettings != null) 'app_settings': jsonEncode(appSettings),
    });
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
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
                        builder: (_) => Directionality(
                          textDirection: TextDirection.rtl,
                          child: PurchaseInvoiceScreen(apiService: api),
                        ),
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
    if (find.text('استعادة').evaluate().isNotEmpty) {
      await tester.tap(find.text('استعادة'));
      await tester.pumpAndSettle();
    }
  }

  /// Frames enough for dialogs and the fake server; a save in flight spins,
  /// so pumpAndSettle would never return.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  Finder footerSave() => find.ancestor(
    of: find.text('حفظ الفاتورة'),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  );

  testWidgets('without a supplier it is not ready, names the supplier, '
      'and saves nothing', (tester) async {
    final api = FakePurchaseApi();
    await open(tester, api: api, saved: draft(supplierId: null));

    expect(find.text('غير جاهز للحفظ — اختر المورد'), findsOneWidget);
    expect(find.text('اختر المورد'), findsOneWidget); // the field's label

    await tester.tap(footerSave());
    await tester.pumpAndSettle();

    expect(api.added, isEmpty);
    expect(find.text('مراجعة الفاتورة'), findsNothing);
    expect(find.text('اختر المورد'), findsNWidgets(2)); // and under it
  });

  testWidgets('a ready invoice is saved once, however often it is pressed', (
    tester,
  ) async {
    final api = FakePurchaseApi()..hold = Completer<void>();
    await open(tester, api: api, saved: draft());

    expect(find.text('جاهز للحفظ'), findsOneWidget);

    await tester.tap(footerSave());
    await settle(tester);
    expect(find.text('مراجعة الفاتورة'), findsOneWidget);
    // Reviewing is not saving; a second press opens nothing.
    expect(find.text('جارٍ الحفظ…'), findsNothing);
    await pressCtrlS(tester);
    expect(find.text('مراجعة الفاتورة'), findsOneWidget);

    await tester.tap(find.text('حفظ الفاتورة').last);
    await settle(tester);
    expect(find.text('جارٍ الحفظ…'), findsOneWidget);
    await pressCtrlS(tester);
    expect(api.added, hasLength(1));

    api.hold!.complete();
    await settle(tester);
    expect(api.added, hasLength(1));
    expect(find.text('تم حفظ الفاتورة'), findsOneWidget);
  });

  testWidgets('Ctrl+S saves a ready invoice', (tester) async {
    final api = FakePurchaseApi();
    await open(tester, api: api, saved: draft());

    await pressCtrlS(tester);
    expect(find.text('مراجعة الفاتورة'), findsOneWidget);
    await tester.tap(find.text('حفظ الفاتورة').last);
    await settle(tester);

    expect(api.added, hasLength(1));
    expect(api.added.single['supplier_id'], 1);
    expect(api.added.single['settlement_method'], 'credit');
  });

  testWidgets('leaving with items in the invoice asks first', (tester) async {
    final api = FakePurchaseApi();
    await open(tester, api: api, saved: draft());

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('فاتورة غير محفوظة'), findsOneWidget);

    await tester.tap(find.text('متابعة التحرير'));
    await tester.pumpAndSettle();
    expect(find.byType(PurchaseInvoiceScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('خروج دون حفظ'));
    await tester.pumpAndSettle();
    expect(find.byType(PurchaseInvoiceScreen), findsNothing);
    expect(api.added, isEmpty);
  });

  testWidgets('leaving an empty invoice does not ask', (tester) async {
    await open(tester, api: FakePurchaseApi());

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('فاتورة غير محفوظة'), findsNothing);
    expect(find.byType(PurchaseInvoiceScreen), findsNothing);
  });

  testWidgets('gold settled with items and manual weights is not sent, and '
      'no item is dropped silently', (tester) async {
    final api = FakePurchaseApi();
    await open(
      tester,
      api: api,
      saved: draft(
        settlement: 'barter',
        karatLines: [
          {'karat': 21, 'weight_grams': 3.0, 'wage_per_gram': 0},
        ],
        goldSettlements: [
          {'safe_box_id': 5, 'karat': 21, 'weight': '10.000'},
        ],
      ),
    );

    expect(
      find.text(
        'غير جاهز للحفظ — مع سداد الذهب تُدخل الأوزان من الأصناف أو من '
        'الأوزان اليدوية، لا من الاثنين',
      ),
      findsOneWidget,
    );
    await tester.tap(footerSave());
    await tester.pumpAndSettle();
    expect(api.added, isEmpty);
  });

  testWidgets('the wage treatment is the company\'s, shown and not chosen '
      '(ADR-039)', (tester) async {
    await open(
      tester,
      api: FakePurchaseApi(),
      saved: draft(),
      appSettings: {'manufacturing_wage_mode': 'inventory'},
    );

    expect(find.text('رسملة في مخزون أجور المصنعية'), findsOneWidget);
    expect(
      find.text('حسب إعدادات الشركة، وتُغيَّر من شاشة الإعدادات.'),
      findsOneWidget,
    );
    expect(find.text('تحميل على المصروفات'), findsNothing); // no toggle
  });
}
