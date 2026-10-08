import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_return_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sales_api.dart';

/// RETURN-LIMIT-1 (the owner, 8 Oct 2026): a return gives back what was sold
/// and no more. All nine customer returns on the 6 Oct copy were whole returns
/// at the original's total; the screen read «1,000» as one riyal, took a
/// refund larger than the sale, and saved twice when pressed twice.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  final original = <String, dynamic>{
    'id': 10,
    'invoice_type': 'بيع',
    'customer_id': 8,
    'branch_id': 1,
    'total': 1000.0,
    'total_weight': 2.0,
    'total_tax': 0.0,
    'items': [
      {
        'id': 100,
        'name': 'سلسال',
        'karat': 21,
        'weight': 2.0,
        'quantity': 1,
        'price': 1000.0,
        'net': 1000.0,
        'tax': 0.0,
        'wage': 0.0,
      },
    ],
  };

  Future<FakeSalesApi> open(
    WidgetTester tester, {
    FakeSalesApi? api,
  }) async {
    api ??= FakeSalesApi(invoices: {10: original});
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
                          child: AddReturnInvoiceScreen(
                            api: api!,
                            returnType: 'مرتجع بيع',
                            prefilledOriginalInvoice: original,
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
    return api;
  }

  /// A return of part of the sale is the wizard, one tap from the whole one.
  Future<void> partial(WidgetTester tester) async {
    await tester.tap(find.text('إرجاع جزء فقط'));
    await tester.pumpAndSettle();
  }

  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.text('التالي').hitTestable());
    await tester.pumpAndSettle();
  }

  /// To the payment step: items (all of them), a reason, then the method.
  Future<void> toPayment(WidgetTester tester) async {
    await next(tester); // the items are already chosen
    await tester.enterText(find.byType(TextFormField).at(1), 'عيب في الصنع');
    await next(tester);
    await tester.tap(find.text('وسيلة الدفع').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('نقداً').last);
    await tester.pumpAndSettle();
  }

  Future<void> refund(WidgetTester tester, String amount) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'المبلغ المسترجع (المعتمد للتسوية)'),
      amount,
    );
  }

  Future<double> refundSent(WidgetTester tester, String typed) async {
    final api = FakeSalesApi(invoices: {10: original});
    await open(tester, api: api);
    await partial(tester);
    await toPayment(tester);
    await refund(tester, typed);
    await next(tester);
    await tester.tap(find.text('حفظ').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('اعتماد وحفظ'));
    await tester.pumpAndSettle();
    return ((api.added.single['payments'] as List).single as Map)['amount']
        as double;
  }

  testWidgets('a refund typed with a thousands comma is a thousand', (
    tester,
  ) async {
    expect(await refundSent(tester, '1,000'), 1000.0);
  });

  testWidgets('a refund in Arabic digits is read', (tester) async {
    expect(await refundSent(tester, '١٠٠٠'), 1000.0);
  });

  testWidgets('an Arabic decimal mark is a decimal', (tester) async {
    expect(await refundSent(tester, '٩٩٩٫٥'), 999.5);
  });

  testWidgets('a refund larger than the sale is refused', (tester) async {
    await open(tester);
    await partial(tester);
    await toPayment(tester);

    await refund(tester, '1500');
    await next(tester);

    expect(
      find.text('مبلغ المرتجع أكبر من إجمالي الفاتورة الأصلية'),
      findsOneWidget,
    );
    expect(find.text('حفظ').hitTestable(), findsNothing);
  });

  testWidgets('a return is saved once, however often save is pressed', (
    tester,
  ) async {
    final api = FakeSalesApi(invoices: {10: original})
      ..hold = Completer<void>();
    await open(tester, api: api);
    await partial(tester);
    await toPayment(tester);
    await refund(tester, '1000');
    await next(tester);

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('حفظ').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('اعتماد وحفظ'));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(api.added, hasLength(1));
    api.hold!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('leaving after the items asks first', (tester) async {
    await open(tester);
    await partial(tester);
    await next(tester);
    await tester.enterText(find.byType(TextFormField).at(1), 'عيب');
    await next(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('مرتجع غير محفوظ'), findsOneWidget);

    await tester.tap(find.text('خروج دون حفظ'));
    await tester.pumpAndSettle();
    expect(find.byType(AddReturnInvoiceScreen), findsNothing);
  });

  testWidgets('leaving at the start does not ask', (tester) async {
    await open(tester);
    await partial(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('مرتجع غير محفوظ'), findsNothing);
    expect(find.byType(AddReturnInvoiceScreen), findsNothing);
  });

  group('a whole return is one page (RETURN-FULL-1)', () {
    Future<void> reason(WidgetTester tester, [String text = 'عيب في الصنع']) =>
        tester.enterText(find.byKey(const Key('return-reason')), text);

    Future<void> pay(WidgetTester tester, int method, [String amount = '']) async {
      if (amount.isNotEmpty) {
        await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), amount);
      }
      await tester.tap(find.byKey(Key('quick-pay-$method')));
      await tester.pumpAndSettle();
    }

    Finder reverseButton() => find.widgetWithText(FilledButton, 'عكس الفاتورة كاملة');

    testWidgets('it shows a copy of the original, to be reversed', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('عكس الفاتورة #10 كاملة'), findsOneWidget);
      expect(find.text('سلسال'), findsWidgets);
      expect(find.textContaining('1000.00'), findsWidgets);
      expect(find.text('اختيار الفاتورة'), findsNothing); // no wizard
    });

    testWidgets('it is not ready without a reason or a refund, and says so', (
      tester,
    ) async {
      await open(tester);
      expect(find.textContaining('غير جاهز للحفظ — اكتب سبب الإرجاع'), findsOneWidget);

      await reason(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('غير جاهز للحفظ — اختر وسيلة الإرجاع'), findsOneWidget);

      await pay(tester, 1);
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('it asks the server to reverse it, sending no amounts of its '
        'own lines', (tester) async {
      final api = FakeSalesApi(invoices: {10: original});
      await open(tester, api: api);
      await reason(tester);
      await pay(tester, 1);

      await tester.tap(reverseButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('عكس وحفظ'));
      await tester.pumpAndSettle();

      expect(api.added, isEmpty);
      expect(api.reversed, hasLength(1));
      final sent = api.reversed.single;
      expect(sent['id'], 10);
      expect(sent['reason'], 'عيب في الصنع');
      expect((sent['payments'] as List).single, {
        'payment_method_id': 1,
        'amount': 1000.0,
      });
    });

    testWidgets('it is refunded by several methods, the last taking the rest', (
      tester,
    ) async {
      final api = FakeSalesApi(
        invoices: {10: original},
        methods: const [
          {'id': 1, 'name': 'نقداً', 'payment_type': 'cash', 'commission_rate': 0, 'display_order': 1},
          {'id': 2, 'name': 'مدى', 'payment_type': 'mada', 'commission_rate': 0, 'display_order': 2},
        ],
      );
      await open(tester, api: api);
      await reason(tester);
      await pay(tester, 1, '٤٠٠');
      expect(find.textContaining('المتبقي: 600.00'), findsWidgets);
      await pay(tester, 2);

      await tester.tap(reverseButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('عكس وحفظ'));
      await tester.pumpAndSettle();

      expect(
        (api.reversed.single['payments'] as List)
            .map((p) => [(p as Map)['payment_method_id'], p['amount']])
            .toList(),
        [
          [1, 400.0],
          [2, 600.0],
        ],
      );
    });

    testWidgets('more than what remains is refused', (tester) async {
      await open(tester);
      await reason(tester);

      await pay(tester, 1, '1500');

      expect(find.textContaining('المتبقي: 1000.00'), findsWidgets);
      expect(find.text('جاهز للحفظ'), findsNothing);
    });

    testWidgets('it is reversed once, however often it is pressed', (
      tester,
    ) async {
      final api = FakeSalesApi(invoices: {10: original})
        ..hold = Completer<void>();
      await open(tester, api: api);
      await reason(tester);
      await pay(tester, 1);

      await tester.tap(reverseButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('عكس وحفظ'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(reverseButton(), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 200));

      expect(api.reversed, hasLength(1));
      api.hold!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('«إرجاع جزء فقط» is the wizard', (tester) async {
      await open(tester);
      await partial(tester);

      expect(find.text('اختيار الفاتورة'), findsOneWidget);
      expect(find.text('الأصناف المرتجعة'), findsWidgets);
    });

    testWidgets('leaving after a reason asks first', (tester) async {
      await open(tester);
      await reason(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('مرتجع غير محفوظ'), findsOneWidget);
    });

    testWidgets('an original not fully paid says so before anything is sent', (
      tester,
    ) async {
      final api = FakeSalesApi(
        invoices: {
          10: {...original, 'amount_paid': 600.0},
        },
      );
      await open(tester, api: api);

      expect(
        find.textContaining('غير مدفوعة بالكامل'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('quick-pay-1')), findsNothing);
    });

    testWidgets('an original that could not be loaded says why, not «loading»', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi()); // invoice 10 is not there

      expect(find.textContaining('تعذّر تحميل الفاتورة'), findsWidgets);
      expect(find.textContaining('جارٍ تحميل الفاتورة'), findsNothing);
    });
  });
}
