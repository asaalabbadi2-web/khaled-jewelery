import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/models/safe_box_model.dart';
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
    int? customerId,
    String customAmount = '',
    int? paymentMethodId = 1,
    List<Map<String, dynamic>> payments = const [],
  }) => {
    'version': 1,
    'branch_id': 1,
    'customer_id': customerId,
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
    bool scrap = false,
    int? editId,
    Map<String, dynamic>? editData,
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
                            scrap: scrap,
                            editInvoiceId: editId,
                            editInvoiceData: editData,
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

  /// Paying is a method's button: it takes the amount typed, or what remains.
  Finder addPaymentButton() => find.byKey(const Key('quick-pay-1'));

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
        saved: draft(customerId: 30),
        customers: [
          {'id': 30, 'name': 'مؤسسة الأمل'},
        ],
        appSettings: {'allow_partial_invoice_payments': true},
      );

      final button = tester.widget<FilledButton>(saveButton());
      expect(button.onPressed, isNotNull);
      await tester.tap(saveButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      expect(api.added.single['amount_paid'], 0);
      expect(api.added.single['customer_id'], 30);
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
    testWidgets('a weight typed in Arabic digits is taken, in its cell', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      await tester.enterText(find.widgetWithText(TextField, '10.000'), '١٢٫٥');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('12.500'), findsOneWidget);
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

    testWidgets('the manual line says its weight is the line\'s, and does '
        'not say the count multiplies it', (tester) async {
      await open(tester, api: FakeSalesApi());

      await tester.tap(find.byTooltip('إضافة صنف يدوي'));
      await tester.pumpAndSettle();

      expect(find.text('الوزن الكلي للسطر (جم)'), findsOneWidget);
      expect(find.textContaining('سيُضرب'), findsNothing);
      expect(find.text('العدد'), findsWidgets);
    });
  });

  group('ready, said and kept (stage 2)', () {
    Future<void> pressCtrlS(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    testWidgets('a sale paid in full says it is ready', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(payments: paidInFull),
      );
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('an unpaid sale says what remains', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());
      expect(
        find.textContaining('غير جاهز للحفظ — أكمل الدفع: يتبقى 1000.00'),
        findsOneWidget,
      );
    });

    testWidgets('a credit sale to the cash customer says it needs a name', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(),
        appSettings: {'allow_partial_invoice_payments': true},
      );
      expect(
        find.textContaining(
          'غير جاهز للحفظ — البيع الآجل يحتاج عميلًا مسمّى، يتبقى 1000.00',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an empty invoice says to add lines', (tester) async {
      await open(tester, api: FakeSalesApi());
      expect(find.text('أضف أصناف الفاتورة'), findsWidgets);
    });

    testWidgets('Ctrl+S opens the review of a ready sale, and does nothing '
        'for one that is not', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(payments: paidInFull),
      );
      await pressCtrlS(tester);
      expect(find.text('مراجعة الفاتورة'), findsOneWidget);
    });

    testWidgets('Ctrl+S is still heard after a field is left with Enter', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(payments: paidInFull),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'امسح الباركود أو ابحث...'),
        'لا شيء',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await pressCtrlS(tester);
      expect(find.text('مراجعة الفاتورة'), findsOneWidget);
    });

    testWidgets('the review says what was sold, to whom and what is owed', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(customerId: 30),
        customers: [
          {'id': 30, 'name': 'مؤسسة الأمل'},
        ],
        appSettings: {'allow_partial_invoice_payments': true},
      );
      await pressCtrlS(tester);

      expect(find.text('مراجعة الفاتورة'), findsOneWidget);
      expect(find.textContaining('سلسال'), findsWidgets); // the line
      expect(find.textContaining('مؤسسة الأمل'), findsWidgets);
      expect(
        find.textContaining('آجلًا على «مؤسسة الأمل»'),
        findsOneWidget,
      );
    });

    testWidgets('a price far from the market is flagged in the review', (
      tester,
    ) async {
      // 10 g at 100,000: 10,000 a gram against a market of 480 (24k).
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(total: 100000, payments: [
          {...paidInFull.first, 'amount': 100000.0, 'net_amount': 100000.0},
        ]),
      );
      await pressCtrlS(tester);

      expect(find.textContaining('أعلى بكثير من سعر السوق'), findsOneWidget);
    });

    testWidgets('leaving with items in the invoice asks first', (
      tester,
    ) async {
      final api = FakeSalesApi();
      await open(tester, api: api, saved: draft());

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('فاتورة غير محفوظة'), findsOneWidget);

      await tester.tap(find.text('متابعة التحرير'));
      await tester.pumpAndSettle();
      expect(find.byType(SalesInvoiceScreenV2), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('خروج دون حفظ'));
      await tester.pumpAndSettle();
      expect(find.byType(SalesInvoiceScreenV2), findsNothing);
      expect(api.added, isEmpty);
    });

    testWidgets('leaving an empty invoice does not ask', (tester) async {
      await open(tester, api: FakeSalesApi());

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('فاتورة غير محفوظة'), findsNothing);
      expect(find.byType(SalesInvoiceScreenV2), findsNothing);
    });
  });

  group('category lines typed in one row (stage 3)', () {
    const categories = [
      {'id': 1, 'name': 'بناجر', 'karat': 21, 'default_wage': 15},
      {'id': 2, 'name': 'سلاسل'},
      {'id': 3, 'name': 'خواتم', 'karat': 18},
    ];

    Future<void> pick(WidgetTester tester, String typed, String name) async {
      await tester.enterText(
        find.byKey(const Key('sales-entry-category')),
        typed,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }

    Future<void> weigh(WidgetTester tester, String weight) async {
      await tester.enterText(
        find.byKey(const Key('sales-entry-weight')),
        weight,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    testWidgets('a line is typed and added with Enter, no dialog', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(categories: categories));

      await pick(tester, 'سل', 'سلاسل');
      await weigh(tester, '٥٫٢٥');

      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(TextField, '5.250'), findsOneWidget); // in the table
      expect(find.text('1 صنف'), findsWidgets);
      // The weight is cleared and held for the next line.
      final field = tester.widget<TextField>(
        find.byKey(const Key('sales-entry-weight')),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('a category with a karat holds it, and one with a wage', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(categories: categories));

      await pick(tester, 'بنا', 'بناجر');

      expect(find.text('الأجرة من التصنيف'), findsOneWidget);
      expect(find.text('عيار التصنيف 21'), findsOneWidget);
      await weigh(tester, '30');
      expect(find.text('15.00'), findsWidgets); // the category's wage
    });

    testWidgets('the weight is the line\'s and the count a note', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(categories: categories));

      await pick(tester, 'سل', 'سلاسل');
      await tester.enterText(find.byKey(const Key('sales-entry-count')), '6');
      await weigh(tester, '63.4');

      expect(find.widgetWithText(TextField, '63.400'), findsOneWidget);
      expect(find.text('العدد'), findsWidgets);
    });

    testWidgets('without a category nothing is added, and it says so', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(categories: categories));

      await weigh(tester, '5');

      expect(find.text('اختر التصنيف'), findsOneWidget);
      expect(find.text('لم تتم إضافة أصناف بعد'), findsOneWidget);
    });

    testWidgets('an amount typed fixes the line\'s total', (tester) async {
      await open(tester, api: FakeSalesApi(categories: categories));

      await pick(tester, 'سل', 'سلاسل');
      await tester.enterText(
        find.byKey(const Key('sales-entry-amount')),
        '٢٬٥٠٠',
      );
      await weigh(tester, '5');

      expect(find.textContaining('2500.00'), findsWidgets);
    });

    testWidgets('a removed line goes at once and can be put back', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      await tester.tap(find.byTooltip('حذف'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('لم تتم إضافة أصناف بعد'), findsOneWidget);

      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect(find.text('لم تتم إضافة أصناف بعد'), findsNothing);
    });
  });

  group('paying with one tap (stage 4)', () {
    testWidgets('a method pays what remains, in one press', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      await tester.tap(find.byKey(const Key('quick-pay-1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('جاهز للحفظ'), findsOneWidget);
      expect(find.textContaining('تم الدفع بالكامل'), findsOneWidget);
      expect(find.byKey(const Key('quick-pay-1')), findsNothing);
    });

    testWidgets('with an amount typed, the method pays that amount', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), '٤٠٠');
      await tester.tap(find.byKey(const Key('quick-pay-1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('المتبقي: 600.00'), findsWidgets);
      // And what remains can be paid the same way.
      expect(find.byKey(const Key('quick-pay-1')), findsOneWidget);
    });

    testWidgets('a paid sale offers no method to pay with', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(payments: paidInFull),
      );
      expect(find.byKey(const Key('quick-pay-1')), findsNothing);
    });

    testWidgets('an empty invoice offers none either', (tester) async {
      await open(tester, api: FakeSalesApi());
      expect(find.byKey(const Key('quick-pay-1')), findsNothing);
    });
  });

  group('one summary, said once (stage 5)', () {
    testWidgets('the total, what is paid and what remains are one card', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      expect(find.text('ملخص الفاتورة'), findsOneWidget);
      // The total is said once in the side column, not in three places.
      expect(find.textContaining('1000.00 ر.س'), findsWidgets);
      expect(find.text('إجمالي الفاتورة:'), findsNothing);
      expect(find.text('الإجمالي الكلي'), findsNothing);
      expect(find.textContaining('الإجمالي: 1000.00'), findsNothing);
    });

    testWidgets('the cost card is gone', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());
      expect(find.text('معلومات التكلفة والتسعير'), findsNothing);
    });

    testWidgets('a target amount typed in the summary is spread over the '
        'lines', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());

      expect(find.text('توزيع تلقائي للمبلغ'), findsNothing); // no big button
      await tester.enterText(
        find.byKey(const Key('target-amount')),
        '٢٠٠٠',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.textContaining('2000.00 ر.س'), findsWidgets);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('the customer is said once', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        saved: draft(customerId: 30),
        customers: [
          {'id': 30, 'name': 'مؤسسة الأمل', 'phone': '0500000000'},
        ],
      );
      expect(find.textContaining('مؤسسة الأمل'), findsOneWidget);
    });
  });

  group('one way to pay, any number of methods (stage 4b)', () {
    const methods = [
      {'id': 1, 'name': 'نقداً', 'payment_type': 'cash', 'commission_rate': 0, 'display_order': 1},
      {'id': 2, 'name': 'مدى', 'payment_type': 'mada', 'commission_rate': 0, 'display_order': 2},
      {'id': 3, 'name': 'تمارا', 'payment_type': 'tamara', 'commission_rate': 0, 'display_order': 5},
      {'id': 4, 'name': 'تحويل', 'payment_type': 'bank_transfer', 'commission_rate': 0, 'display_order': 999},
    ];

    Future<void> pay(WidgetTester tester, String amount, int method) async {
      if (amount.isNotEmpty) {
        await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), amount);
      }
      await tester.tap(find.byKey(Key('quick-pay-$method')));
      await tester.pumpAndSettle();
    }

    testWidgets('the old picker and its add button are gone', (tester) async {
      await open(tester, api: FakeSalesApi(methods: methods), saved: draft());

      expect(find.text('إضافة وسيلة دفع'), findsNothing);
      expect(find.text('اختر وسيلة الدفع'), findsNothing);
      expect(find.byType(DropdownButtonFormField<int>), findsOneWidget); // the branch
    });

    testWidgets('three methods: two amounts typed, the last takes the rest', (
      tester,
    ) async {
      final api = FakeSalesApi(methods: methods);
      await open(tester, api: api, saved: draft(total: 10000));

      await pay(tester, '3000', 1);
      expect(find.textContaining('المتبقي: 7000.00'), findsOneWidget);
      await pay(tester, '٤٠٠٠', 2);
      await pay(tester, '', 3);

      expect(find.textContaining('تم الدفع بالكامل'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      final paid = (api.added.single['payments'] as List)
          .map((p) => [(p as Map)['payment_method_id'], p['amount']])
          .toList();
      expect(paid, [
        [1, 3000.0],
        [2, 4000.0],
        [3, 3000.0],
      ]);
    });

    testWidgets('the same method twice is two payments', (tester) async {
      await open(tester, api: FakeSalesApi(methods: methods), saved: draft());

      await pay(tester, '600', 2);
      await pay(tester, '', 2);

      expect(find.textContaining('تم الدفع بالكامل'), findsOneWidget);
    });

    testWidgets('more than what remains is refused', (tester) async {
      await open(tester, api: FakeSalesApi(methods: methods), saved: draft());

      await pay(tester, '2000', 1);

      expect(find.textContaining('أكبر من المتبقي'), findsOneWidget);
      expect(find.textContaining('المتبقي: 1000.00'), findsOneWidget);
    });

    testWidgets('the field shows what remains while it is empty', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(methods: methods), saved: draft());
      await pay(tester, '250', 1);

      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'المبلغ'),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.decoration!.hintText, '750.00');
    });

    testWidgets('Alt+1 pays with the first method', (tester) async {
      await open(tester, api: FakeSalesApi(methods: methods), saved: draft());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.textContaining('تم الدفع بالكامل'), findsOneWidget);
      expect(find.textContaining('نقداً'), findsWidgets);
    });

    testWidgets('the first two in the settings\' order stand out', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(methods: methods.reversed.toList()),
        saved: draft(),
      );

      bool filled(int id) =>
          tester.widget(find.byKey(Key('quick-pay-$id'))) is FilledButton;
      expect(filled(1), isTrue);
      expect(filled(2), isTrue);
      expect(filled(3), isFalse);
      expect(filled(4), isFalse);
    });

    testWidgets('a payment\'s safe is its method\'s default, and is changed '
        'on its line', (tester) async {
      final api = FakeSalesApi(
        methods: methods,
        safes: [
          SafeBoxModel(id: 7, name: 'صندوق الفرع', safeType: 'cash', accountId: 70, isDefault: true),
          SafeBoxModel(id: 8, name: 'صندوق الموظف', safeType: 'cash', accountId: 80),
        ],
      );
      await open(tester, api: api, saved: draft(customerId: null));

      await pay(tester, '', 1);
      expect(find.text('صندوق الفرع'), findsOneWidget);

      await tester.tap(find.text('صندوق الفرع'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('صندوق الموظف').last);
      await tester.pumpAndSettle();
      expect(find.text('صندوق الموظف'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      expect((api.added.single['payments'] as List).single['safe_box_id'], 8);
    });
  });

  group('a scrap sale is this screen, in its mode (SALES-UX-7)', () {
    final scrapSafe = SafeBoxModel(
      id: 31,
      name: 'خزينة الكسر الرئيسية',
      safeType: 'gold',
      accountId: 310,
    );
    final goldSafe = SafeBoxModel(
      id: 32,
      name: 'خزينة الذهب',
      safeType: 'gold',
      accountId: 320,
    );

    Future<Map<String, dynamic>> save(
      WidgetTester tester,
      FakeSalesApi api,
    ) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      return api.added.single;
    }

    testWidgets('it says it is a scrap sale', (tester) async {
      await open(tester, api: FakeSalesApi(), scrap: true);
      expect(find.text('فاتورة بيع الكسر'), findsOneWidget);
    });

    testWidgets('it sends a scrap sale out of the main scrap safe', (
      tester,
    ) async {
      final api = FakeSalesApi(
        settings: {'main_scrap_gold_safe_box_id': 31},
        scrapSafe: scrapSafe,
        goldSafe: goldSafe,
      );
      await open(
        tester,
        api: api,
        saved: draft(payments: paidInFull),
        scrap: true,
      );

      final sent = await save(tester, api);
      expect(sent['gold_type'], 'scrap');
      expect(sent['invoice_type'], 'بيع');
      expect(sent['safe_box_id'], 31);
    });

    testWidgets('with no main scrap safe set, the default gold safe', (
      tester,
    ) async {
      final api = FakeSalesApi(goldSafe: goldSafe);
      await open(
        tester,
        api: api,
        saved: draft(payments: paidInFull),
        scrap: true,
      );

      final sent = await save(tester, api);
      expect(sent['safe_box_id'], 32);
    });

    testWidgets('a sale of new gold sends neither a kind nor that safe', (
      tester,
    ) async {
      final api = FakeSalesApi(
        settings: {'main_scrap_gold_safe_box_id': 31},
        scrapSafe: scrapSafe,
      );
      await open(tester, api: api, saved: draft(payments: paidInFull));

      final sent = await save(tester, api);
      expect(sent.containsKey('gold_type'), isFalse);
      expect(sent.containsKey('safe_box_id'), isFalse);
    });

    testWidgets('a scrap sale offers no barter: barter buys scrap in', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), saved: draft(), scrap: true);
      expect(find.text('مقايضة ذهب كسر'), findsNothing);
    });

    testWidgets('a sale of new gold still offers it', (tester) async {
      await open(tester, api: FakeSalesApi(), saved: draft());
      expect(find.text('مقايضة ذهب كسر'), findsOneWidget);
    });

    testWidgets('editing keeps its kind, its safe and its lines\' totals', (
      tester,
    ) async {
      final api = FakeSalesApi(goldSafe: goldSafe);
      await open(
        tester,
        api: api,
        scrap: true,
        editId: 1540,
        editData: {
          'customer_id': 8,
          'branch_id': 1,
          'gold_type': 'scrap',
          'safe_box_id': 31,
          'items': [
            {'name': 'كسر', 'karat': 21, 'weight': 3.0, 'wage': 0,
             'quantity': 1, 'net': 1200.0, 'tax': 0.0, 'price': 1200.0},
          ],
          'payments': [
            {'payment_method_id': 1, 'payment_method_name': 'نقداً',
             'amount': 1200.0, 'commission_rate': 0, 'commission_amount': 0,
             'commission_vat': 0, 'net_amount': 1200.0, 'settlement_days': 0},
          ],
        },
        customers: [
          {'id': 8, 'name': 'عميل نقدي'},
        ],
      );
      expect(find.text('تعديل فاتورة بيع الكسر'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);

      expect(api.added, isEmpty);
      final sent = api.updated.single;
      expect(sent['gold_type'], 'scrap');
      expect(sent['safe_box_id'], 31); // the invoice's own, not today's default
      expect(sent['total'], 1200.0);
    });
  });
}
