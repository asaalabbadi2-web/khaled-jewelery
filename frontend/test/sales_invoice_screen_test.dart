import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/sales_invoice_screen_v2.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sales_api.dart';

/// SALES-UX-1 (the owner, 7 Oct 2026): the sales screen records what was
/// typed and sold -- no amount, weight or customer the seller did not mean.
/// Measured on the 6 Oct production copy: 2575 of 2576 sale lines are manual
/// or category lines; 21 «عميل نقدي» customers where there is to be one.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  const draftKey = 'yasargold_sales_invoice_complete_later_v2';

  /// One manual line of 10 g of 21k sold at [total] (1,000.00) in all.
  Map<String, dynamic> draft({
    double total = 1000.0,
    String customAmount = '',
    int? paymentMethodId = 1,
    List<Map<String, dynamic>> payments = const [],
  }) => {
    'version': 1,
    'branch_id': 1,
    'custom_amount': customAmount,
    'selected_payment_method_id': paymentMethodId,
    'payments': payments,
    'items': [
      {
        'name': 'سلسال',
        'karat': 21,
        'weight': 10.0,
        'wage': 0,
        'count': 1,
        'tax_rate': 0,
        'has_manual_total': true,
        'manual_total': total,
      },
    ],
  };

  const paidInFull = [
    {
      'payment_method_id': 1,
      'payment_method_name': 'نقداً',
      'amount': 1000.0,
      'commission_rate': 0,
      'commission_amount': 0,
      'commission_vat': 0,
      'net_amount': 1000.0,
      'settlement_days': 0,
    },
  ];

  Future<void> open(
    WidgetTester tester, {
    required FakeSalesApi api,
    Map<String, dynamic>? saved,
    Map<String, dynamic> appSettings = const {},
    List<Map<String, dynamic>> items = const [],
    List<Map<String, dynamic>> customers = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      if (saved != null) draftKey: jsonEncode(saved),
      'app_settings': jsonEncode({
        'sales_vat_enabled': false,
        'main_karat': 21,
        ...appSettings,
      }),
    });
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // The screen reads the settings it is given; the app loads them at start.
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
                        builder: (_) => Directionality(
                          textDirection: TextDirection.rtl,
                          child: SalesInvoiceScreenV2(
                            // The app hands copies it may add to.
                            items: List.of(items),
                            customers: List.of(customers),
                            apiService: api,
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

  /// A save in flight spins; pumpAndSettle would not return.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The screen's own save button (its label says what is due when unpaid).
  Finder saveButton() => find.ancestor(
    of: find.byIcon(Icons.check_circle_outline),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  );

  Finder addPaymentButton() => find.ancestor(
    of: find.text('إضافة'),
    matching: find.byWidgetPredicate((w) => w is ElevatedButton),
  );

  group('money as typed (stage 1)', () {
    testWidgets('an amount typed in Arabic digits is the amount paid, not '
        'the whole remainder', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(customAmount: '٥٠٠'),
      );

      await tester.tap(addPaymentButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('المتبقي: 500.00'), findsOneWidget);
    });

    testWidgets('an amount typed with a thousands comma is read too', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft(total: 2500));

      await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), '1,000');
      await tester.tap(addPaymentButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('المتبقي: 1500.00'), findsOneWidget);
    });

    testWidgets('an amount it cannot read adds nothing, and says so', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(customAmount: '5o0'),
      );

      await tester.tap(addPaymentButton());
      await tester.pumpAndSettle();

      expect(find.textContaining('المتبقي: 1000.00'), findsOneWidget);
      expect(find.textContaining('لم يُقرأ المبلغ'), findsOneWidget);
    });

    testWidgets('a sale is saved once, however often save is pressed', (
      tester,
    ) async {
      final api = FakeSalesApi()..hold = Completer<void>();
      await open(
        tester,
        api: api,
        saved: draft(payments: paidInFull),
      );

      await tester.tap(saveButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      expect(api.added, hasLength(1));

      await tester.tap(saveButton(), warnIfMissed: false);
      await settle(tester);
      expect(find.text('مراجعة الفاتورة'), findsNothing);
      expect(api.added, hasLength(1));
      api.hold!.complete();
      await settle(tester);
    });
  });

  group('a sale on credit (stage 1)', () {
    testWidgets('with partial payments on, an unpaid sale can be saved', (
      tester,
    ) async {
      final api = FakeSalesApi();
      await open(
        tester,
        api: api,
        saved: draft(),
        appSettings: {'allow_partial_invoice_payments': true},
      );

      final button = tester.widget<FilledButton>(saveButton());
      expect(button.onPressed, isNotNull);
      await tester.tap(saveButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      expect(api.added.single['amount_paid'], 0);
    });

    testWidgets('with them off, it is paid in full first', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      final button = tester.widget<FilledButton>(saveButton());
      expect(button.onPressed, isNull);
    });
  });

  group('each piece is unique (stage 1)', () {
    const piece = {
      'id': 5,
      'name': 'خاتم سوليتير',
      'barcode': 'YAS000005',
      'karat': 21,
      'weight': 4.25,
      'wage': 0,
    };

    Future<void> scan(WidgetTester tester, String code) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'امسح الباركود أو ابحث...'),
        code,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    testWidgets('a piece scanned twice is in the invoice once', (tester) async {
      await open(tester, api: FakeSalesApi(), items: [piece]);

      await scan(tester, 'YAS000005');
      await scan(tester, 'YAS000005');

      expect(find.text('1 صنف'), findsWidgets);
      expect(find.textContaining('مضافة في الفاتورة'), findsOneWidget);
    });

    testWidgets('a piece without a weight is not sold at an invented one', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        items: [
          {...piece, 'weight': 0},
        ],
      );

      await scan(tester, 'YAS000005');

      expect(find.text('لم تتم إضافة أصناف بعد'), findsOneWidget);
      expect(find.textContaining('بلا وزن'), findsOneWidget);
    });

    testWidgets('part of a name shared by several pieces asks which', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        items: [
          piece,
          {...piece, 'id': 6, 'name': 'خاتم توينز', 'barcode': 'YAS000006'},
        ],
      );

      await scan(tester, 'خاتم');

      expect(find.text('اختر صنف'), findsOneWidget);
      expect(find.text('لم تتم إضافة أصناف بعد'), findsOneWidget);
    });
  });

  group('the cash customer is one (stage 1)', () {
    testWidgets('a sale without a customer goes to the first «عميل نقدي», '
        'and none is created', (tester) async {
      final api = FakeSalesApi();
      await open(
        tester,
        api: api,
        saved: draft(payments: paidInFull),
        customers: [
          {'id': 30, 'name': 'مؤسسة النقد للمجوهرات'},
          {'id': 13, 'name': 'عميل نقدي'},
          {'id': 8, 'name': 'عميل نقدي'},
        ],
      );

      await tester.tap(saveButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);

      expect(api.added.single['customer_id'], 8);
      expect(api.customersAdded, isEmpty);
    });
  });

  group('lines edited as typed (stage 1)', () {
    testWidgets('a weight typed in Arabic digits is taken', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      await tester.tap(find.text('10.00'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '١٢٫٥');
      await tester.tap(find.widgetWithText(ElevatedButton, 'حفظ'));
      await tester.pumpAndSettle();

      expect(find.text('12.50'), findsOneWidget);
    });

    testWidgets('a karat other than 18, 21, 22 or 24 is refused', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      await tester.tap(find.text('21').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '25');
      await tester.tap(find.widgetWithText(ElevatedButton, 'حفظ'));
      await tester.pumpAndSettle();

      expect(find.textContaining('18 أو 21 أو 22 أو 24'), findsOneWidget);
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(find.text('25'), findsNothing);
      expect(find.text('21'), findsWidgets);
    });

    testWidgets('the manual line says its weight is the line\'s, and the '
        'count is a note', (tester) async {
      await open(tester, api: FakeSalesApi());

      await tester.tap(find.byTooltip('إضافة صنف يدوي'));
      await tester.pumpAndSettle();

      expect(find.text('الوزن الكلي للسطر (جم)'), findsOneWidget);
      expect(find.textContaining('سيُضرب'), findsNothing);
      expect(find.text('للبيان فقط، لا يُضرب في الوزن'), findsOneWidget);
    });
  });
}
