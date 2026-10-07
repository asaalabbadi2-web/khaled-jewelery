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
    String cashPaid = '0.00',
    List<Map<String, dynamic>> karatLines = const [],
    List<Map<String, dynamic>> goldSettlements = const [],
    bool withItem = true,
    bool manualPricing = false,
  }) => {
    'version': 1,
    'supplier_id': supplierId,
    'branch_id': 1,
    'settlement_mode': settlement,
    'cash_paid': cashPaid,
    'selected_payment_method_id': 1,
    'selected_gold_paid_karat': 21,
    'gold_settlements': goldSettlements,
    'karat_lines': karatLines,
    'manual_pricing': manualPricing,
    'inline_items': [
      if (withItem)
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
    Map<String, Object> prefs = const {},
    Map<String, dynamic>? editing,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (saved != null) draftKey: jsonEncode(saved),
      if (appSettings != null) 'app_settings': jsonEncode(appSettings),
      ...prefs,
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
                          child: PurchaseInvoiceScreen(
                            apiService: api,
                            editInvoiceId: editing == null ? null : 77,
                            editInvoiceData: editing,
                          ),
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

  testWidgets('Ctrl+S is still heard after a field is left with Enter', (
    tester,
  ) async {
    // A field done with Enter gave focus to the route, above the shortcuts.
    await open(tester, api: FakePurchaseApi(), saved: draft());

    await tester.enterText(find.widgetWithText(TextField, '18.00'), '20');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await pressCtrlS(tester);
    expect(find.text('مراجعة الفاتورة'), findsOneWidget);
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

  group(
    'VAT is decided on the invoice, from the supplier (PURCHASE-VAT-1)',
    () {
      Future<Map<String, dynamic>> save(
        WidgetTester tester,
        FakePurchaseApi api,
      ) async {
        await pressCtrlS(tester);
        await tester.tap(find.text('حفظ الفاتورة').last);
        await settle(tester);
        return api.added.single;
      }

      testWidgets('a supplier with a tax number starts with VAT', (
        tester,
      ) async {
        final api = FakePurchaseApi();
        await open(tester, api: api, saved: draft(supplierId: 1));

        expect(find.text('حسب المورد: له رقم ضريبي'), findsOneWidget);
        final sent = await save(tester, api);
        expect(sent['vat_applied'], isTrue);
        expect(sent['wage_tax_total'], greaterThan(0));
      });

      testWidgets('a supplier without one starts without', (tester) async {
        final api = FakePurchaseApi();
        await open(tester, api: api, saved: draft(supplierId: 2));

        expect(find.text('حسب المورد: ليس له رقم ضريبي'), findsOneWidget);
        final sent = await save(tester, api);
        expect(sent['vat_applied'], isFalse);
        expect(sent['wage_tax_total'], 0);
        expect(sent['total_tax'], 0);
      });

      testWidgets(
        'changed for one invoice, the review says it is an exception',
        (tester) async {
          final api = FakePurchaseApi();
          await open(tester, api: api, saved: draft(supplierId: 1));

          await tester.tap(find.text('بلا ضريبة'));
          await tester.pumpAndSettle();
          expect(find.text('غُيِّر لهذه الفاتورة'), findsOneWidget);

          await pressCtrlS(tester);
          expect(find.text('بلا ضريبة، والمورد له رقم ضريبي'), findsOneWidget);
          await tester.tap(find.text('حفظ الفاتورة').last);
          await settle(tester);
          expect(api.added.single['vat_applied'], isFalse);
          expect(api.added.single['wage_tax_total'], 0);
        },
      );

      testWidgets(
        'the old «no VAT» switch kept on the device decides nothing',
        (tester) async {
          final api = FakePurchaseApi();
          await open(
            tester,
            api: api,
            saved: draft(supplierId: 1),
            prefs: {'invoice_ui_settings_v1.purchase.disable_vat': true},
          );

          final sent = await save(tester, api);
          expect(sent['vat_applied'], isTrue);
          expect(sent['wage_tax_total'], greaterThan(0));
        },
      );
    },
  );

  group('weights are entered as items, in one place', () {
    testWidgets('the screen has no manual weights card and no manual pricing', (
      tester,
    ) async {
      await open(tester, api: FakePurchaseApi(), saved: draft());

      expect(find.text('الأوزان اليدوية (اختياري)'), findsNothing);
      expect(find.text('قيمة يدوية'), findsNothing);
      expect(find.text('الأصناف داخل الفاتورة'), findsOneWidget);
    });

    testWidgets('a draft kept with manual weights comes back as items, its '
        'wages kept', (tester) async {
      final api = FakePurchaseApi();
      await open(
        tester,
        api: api,
        saved: draft(
          withItem: false,
          manualPricing: true,
          karatLines: [
            {
              'karat': 21,
              'weight_grams': 10.0,
              'wage_per_gram': 0,
              'gold_value_override': 3000.0,
              'wage_cash_override': 100.0,
            },
          ],
        ),
      );

      expect(find.text('جاهز للحفظ'), findsOneWidget);
      await pressCtrlS(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);

      final sent = api.added.single;
      expect(sent['karat_lines'], anyOf(isNull, isEmpty));
      final item = (sent['items'] as List).single as Map;
      expect(item['karat'], 21);
      expect(item['weight'], 10.0);
      expect(item['wage_total'], closeTo(100.0, 0.001));
      expect(item.containsKey('create_inline'), isFalse); // no new stock item
    });

    testWidgets('an invoice holding weights without items is not edited here, '
        'so they are not dropped', (tester) async {
      final api = FakePurchaseApi();
      await open(
        tester,
        api: api,
        editing: {
          'supplier_id': 1,
          'branch_id': 1,
          'settlement_method': 'credit',
          'items': <Map<String, dynamic>>[],
          'karat_lines': [
            {'karat': 21, 'weight_grams': 69.76, 'gold_value_cash': 35000.0},
          ],
        },
      );

      expect(
        find.text(
          'غير جاهز للحفظ — في هذه الفاتورة أوزان بلا أصناف لا تعرضها هذه '
          'الشاشة، فلا تُعدَّل منها',
        ),
        findsOneWidget,
      );
      await pressCtrlS(tester);
      expect(api.updated, isEmpty);
      expect(api.added, isEmpty);
    });
  });

  group('items typed in one row (PURCHASE-UX-5)', () {
    Future<Map<String, dynamic>> save(
      WidgetTester tester,
      FakePurchaseApi api,
    ) async {
      await pressCtrlS(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      return api.added.single;
    }

    Future<void> typeWeight(WidgetTester tester, String weight) async {
      await tester.enterText(
        find.byKey(const Key('purchase-entry-weight')),
        weight,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    testWidgets('three weights of one item are typed with Enter, no dialog', (
      tester,
    ) async {
      final api = FakePurchaseApi();
      await open(tester, api: api, saved: draft(withItem: false));

      await tester.enterText(
        find.byKey(const Key('purchase-entry-name')),
        'سلسال',
      );
      await tester.enterText(
        find.byKey(const Key('purchase-entry-wage')),
        '١٨',
      );
      for (final w in ['١٢٫٥', '3', '4.25']) {
        await typeWeight(tester, w);
        expect(find.byType(Dialog), findsNothing);
      }
      // The weight is cleared for the next one; the name and wage stay.
      final weightField = tester.widget<TextField>(
        find.byKey(const Key('purchase-entry-weight')),
      );
      expect(weightField.controller!.text, isEmpty);
      expect(weightField.focusNode!.hasFocus, isTrue);

      final items = (await save(tester, api))['items'] as List;
      expect(items.map((i) => (i as Map)['weight']), [12.5, 3.0, 4.25]);
      for (final i in items.cast<Map>()) {
        expect(i['name'], 'سلسال');
        expect(i['karat'], 21);
        expect(i['wage_per_gram'], 18.0);
        expect(i['create_inline'], isTrue);
      }
    });

    testWidgets('without a name nothing is added, and it says so', (
      tester,
    ) async {
      await open(tester, api: FakePurchaseApi(), saved: draft(withItem: false));

      await typeWeight(tester, '5');
      expect(find.text('اكتب اسم الصنف'), findsOneWidget);
      expect(find.text('غير جاهز للحفظ — أضف أصناف الفاتورة'), findsNothing);
      expect(find.textContaining('أضف أصناف الفاتورة'), findsWidgets);
    });

    testWidgets('a weight is corrected in its own cell', (tester) async {
      final api = FakePurchaseApi();
      await open(tester, api: api, saved: draft());

      final cell = find.widgetWithText(TextField, '12.500');
      await tester.enterText(cell, '13');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final item = ((await save(tester, api))['items'] as List).single as Map;
      expect(item['weight'], 13.0);
      expect(item['wage_total'], closeTo(13 * 18, 0.001));
    });

    testWidgets('a removed line is gone at once and can be put back', (
      tester,
    ) async {
      await open(tester, api: FakePurchaseApi(), saved: draft());

      await tester.tap(find.byTooltip('حذف'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(TextField, '12.500'), findsNothing);

      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '12.500'), findsOneWidget);
    });
  });

  group('what we owe the supplier, said in words (stage 3)', () {
    testWidgets('the review says where we stand and what the save does', (
      tester,
    ) async {
      final api = FakePurchaseApi(
        statement: {
          'closing_balance_cash': -1500,
          'closing_balance_gold_normalized': -10,
        },
      );
      await open(tester, api: api, saved: draft());

      await pressCtrlS(tester);
      expect(find.textContaining('علينا له 1500.00'), findsOneWidget);
      expect(find.textContaining('(دائن)'), findsWidgets);
      expect(
        find.textContaining('سيزيد ما علينا للمورد نقدًا'),
        findsOneWidget,
      );
      expect(find.textContaining('سيزداد رصيد المورد'), findsNothing);
    });

    testWidgets('changing how it is settled asks before clearing the cash', (
      tester,
    ) async {
      await open(
        tester,
        api: FakePurchaseApi(),
        saved: draft(settlement: 'partial', cashPaid: '200.00'),
      );

      await tester.tap(find.text('آجل'));
      await tester.pumpAndSettle();
      expect(find.text('تغيير السداد إلى «آجل»'), findsOneWidget);
      expect(find.textContaining('المدفوع نقدًا'), findsWidgets);

      await tester.tap(find.text('إبقاء'));
      await tester.pumpAndSettle();
      expect(find.text('200.00'), findsOneWidget); // still there

      await tester.tap(find.text('آجل'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تغيير ومسح'));
      await tester.pumpAndSettle();
      expect(find.text('200.00'), findsNothing);
    });

    testWidgets('a commission typed in Arabic digits is read', (tester) async {
      await open(
        tester,
        api: FakePurchaseApi(),
        saved: draft(
          settlement: 'partial',
          goldSettlements: [
            {'safe_box_id': 5, 'karat': 21, 'weight': '20.000'},
          ],
        ),
      );

      await tester.tap(find.text('عمولة'));
      await tester.pumpAndSettle();
      final field = find.ancestor(
        of: find.textContaining('/جم'),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(field, '٢٫٥');
      await tester.pumpAndSettle();
      expect(find.textContaining('= 50.00'), findsOneWidget);
    });
  });

  group('one summary, said once (stage 4)', () {
    testWidgets('the dues and the totals are one card', (tester) async {
      await open(tester, api: FakePurchaseApi(), saved: draft());

      expect(find.text('علينا للمورد بهذه الفاتورة'), findsOneWidget);
      expect(find.text('ملخص الفاتورة'), findsNothing);
      expect(find.text('مستحقات المورد'), findsNothing);
      // The gold price is in the app bar, not in a card of its own too.
      expect(find.text('سعر الذهب'), findsNothing);
    });
  });
}
