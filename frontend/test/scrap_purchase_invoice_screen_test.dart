import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/scrap_purchase_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sales_api.dart';

/// SALES-UX-9 (the owner, 8 Oct 2026): the scrap purchase from a customer --
/// 776 of the 6 Oct copy's invoices, 3.9 a day -- records what was typed,
/// says what stands in the way of saving, and pays like the sales screen.
/// Opened in edit mode, which holds the same save flow with lines already in.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Map<String, dynamic> invoice({
    int? customerId,
    double total = 4000,
    List<Map<String, dynamic>> payments = const [],
  }) => {
    'customer_id': customerId,
    'branch_id': 1,
    'items': [
      {
        'name': 'كسر',
        'karat': 21,
        'standing_weight': 10.0,
        'stones_weight': 0.0,
        'weight': 10.0,
        'wage': 0,
        'quantity': 1,
        'price': total,
      },
    ],
    'payments': payments,
  };

  Map<String, dynamic> paid(double amount) => {
    'payment_method_id': 1,
    'payment_method_name': 'نقداً',
    'amount': amount,
    'commission_rate': 0,
    'commission_amount': 0,
    'commission_vat': 0,
    'net_amount': amount,
    'settlement_days': 0,
  };

  Future<void> open(
    WidgetTester tester, {
    required FakeSalesApi api,
    Map<String, dynamic>? editing,
    List<Map<String, dynamic>> customers = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider.value(value: settings),
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
                          child: ScrapPurchaseInvoiceScreen(
                            customers: List.of(customers),
                            apiService: api,
                            editInvoiceId: editing == null ? null : 5,
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
  }

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

  Future<void> payWith(WidgetTester tester, String amount) async {
    if (amount.isNotEmpty) {
      await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), amount);
    }
    await tester.tap(find.byKey(const Key('quick-pay-1')));
    await tester.pumpAndSettle();
  }

  group('one way to pay (stage 4)', () {
    testWidgets('the old picker is gone and a method pays what remains', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());

      expect(find.text('إضافة وسيلة دفع'), findsNothing);
      await payWith(tester, '');

      expect(find.textContaining('تم الدفع بالكامل'), findsWidgets);
    });

    testWidgets('an amount typed in Arabic digits is the amount, not the '
        'whole remainder', (tester) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());

      await payWith(tester, '٥٠٠');

      expect(find.textContaining('المتبقي: 3500.00'), findsWidgets);
    });

    testWidgets('more than remains is refused', (tester) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());

      await payWith(tester, '9000');

      expect(find.textContaining('المتبقي: 4000.00'), findsWidgets);
    });
  });

  group('ready, said and kept (stage 2)', () {
    testWidgets('paid in full it says it is ready', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        editing: invoice(payments: [paid(4000)]),
      );
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('unpaid it says what remains', (tester) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());
      expect(
        find.textContaining('غير جاهز للحفظ — أكمل الدفع: يتبقى 4000.00'),
        findsOneWidget,
      );
    });

    testWidgets('Ctrl+S reviews a ready purchase, named for what it is', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        editing: invoice(payments: [paid(4000)]),
      );
      await pressCtrlS(tester);
      expect(find.text('مراجعة فاتورة شراء كسر'), findsOneWidget);
    });

    testWidgets('it is saved once, however often save is pressed', (
      tester,
    ) async {
      final api = FakeSalesApi()..hold = Completer<void>();
      await open(
        tester,
        api: api,
        editing: invoice(payments: [paid(4000)]),
      );

      await pressCtrlS(tester);
      await tester.tap(find.text('حفظ الفاتورة').last);
      await settle(tester);
      // A buyer whose account is no employee's is told where the gold goes.
      if (find.text('متابعة').evaluate().isNotEmpty) {
        await tester.tap(find.text('متابعة'));
        await settle(tester);
      }
      await pressCtrlS(tester);
      await pressCtrlS(tester);
      expect(api.updated, hasLength(1));
      api.hold!.complete();
      await settle(tester);
    });

    testWidgets('leaving with lines in the invoice asks first', (tester) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('فاتورة غير محفوظة'), findsOneWidget);

      await tester.tap(find.text('خروج دون حفظ'));
      await tester.pumpAndSettle();
      expect(find.byType(ScrapPurchaseInvoiceScreen), findsNothing);
    });
  });

  group('who is the cash customer (stage 1)', () {
    testWidgets('a name that merely contains «نقد» is a customer, and needs '
        'its identity', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        editing: invoice(customerId: 30, payments: [paid(4000)]),
        customers: [
          {'id': 30, 'name': 'مؤسسة النقد للمجوهرات'},
        ],
      );

      expect(
        find.textContaining(
          'العميل «مؤسسة النقد للمجوهرات» بلا رقم هوية أو نسختها أو تاريخ ميلاد',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the walk-in customer needs none', (tester) async {
      await open(
        tester,
        api: FakeSalesApi(),
        editing: invoice(customerId: 8, payments: [paid(4000)]),
        customers: [
          {'id': 8, 'name': 'عميل نقدي'},
        ],
      );
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('a customer with their identity on file is ready', (
      tester,
    ) async {
      await open(
        tester,
        api: FakeSalesApi(),
        editing: invoice(customerId: 31, payments: [paid(4000)]),
        customers: [
          {
            'id': 31,
            'name': 'أحمد',
            'id_number': '1000000000',
            'id_version_number': '1',
            'birth_date': '1990-01-01',
          },
        ],
      );
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });
  });

  group('the invoice says what it is (stage 5)', () {
    testWidgets('the bar is the scrap purchase\'s', (tester) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.backgroundColor, isNotNull);
    });

    testWidgets('a price over the live price is said before saving', (
      tester,
    ) async {
      // 10 g of 21k at 4,500: 450 a gram against a live 420.
      await open(
        tester,
        api: FakeSalesApi(),
        editing: invoice(total: 4500, payments: [paid(4500)]),
      );
      await pressCtrlS(tester);
      expect(find.textContaining('يُحجز لاعتماد المدير'), findsOneWidget);
    });

    testWidgets('the cost column is not shown to every buyer', (tester) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());
      expect(find.text('التكلفة'), findsNothing);
    });
  });

  group('one summary, said once (stage 5)', () {
    testWidgets('the total, what is paid and what remains are one card', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());

      expect(find.text('ملخص الفاتورة'), findsOneWidget);
      expect(find.text('الإجمالي الكلي'), findsNothing);
      expect(find.text('إجمالي الفاتورة:'), findsNothing);
      expect(find.text('توزيع تلقائي للمبلغ'), findsNothing);
    });

    testWidgets('a target amount typed in the summary is spread over the '
        'lines', (tester) async {
      // A line priced by hand keeps its price; this one is priced by weight.
      await open(tester, api: FakeSalesApi(), editing: invoice(total: 0));

      await tester.enterText(find.byKey(const Key('target-amount')), '٥٠٠٠');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.textContaining('5000.00'), findsWidgets);
    });

    testWidgets('the line\'s actions are in view, not behind a scroll', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi(), editing: invoice());

      final actions = tester.getTopLeft(find.byIcon(Icons.delete).first);
      expect(actions.dx, greaterThanOrEqualTo(0));
      expect(actions.dx, lessThan(1440));
    });
  });
}
