import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_return_invoice_screen.dart';
import 'package:frontend/widgets/return_reason_input.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sales_api.dart';
import 'support/shots.dart';

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
    // Its amount typed, with its weight (the owner, 11 Nov 2026).
    await tester.enterText(find.byKey(const ValueKey('amount-100-0')), '1000');
    await tester.pumpAndSettle();
  }

  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.text('التالي').hitTestable());
    await tester.pumpAndSettle();
  }

  /// To the payment step: items (all of them), a reason, then the method.
  Future<void> toPayment(WidgetTester tester) async {
    await next(tester); // the items are already chosen
    await tester.enterText(find.descendant(of: find.byType(ReturnReasonInput), matching: find.byType(TextFormField)), 'عيب في الصنع');
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

  // The return drawn on an iPhone, for looking at (SHOT_DIR; nothing without it).
  testWidgets('the return draws on an iPhone (SHOT_DIR)', (tester) async {
    if (shotDir.isEmpty) return;
    await open(tester);
    tester.view.physicalSize = const Size(390, 1700);
    await tester.pumpAndSettle();
    await shot(tester, 'return_whole_phone');
    await partial(tester);
    await shot(tester, 'return_step_items_phone');
    await next(tester);
    await shot(tester, 'return_step_reason_phone');
    await tester.enterText(find.descendant(of: find.byType(ReturnReasonInput), matching: find.byType(TextFormField)), 'عيب في الصنع');
    await next(tester);
    await shot(tester, 'return_step_payment_phone');
    await tester.tap(find.text('وسيلة الدفع').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('نقداً').last);
    await tester.pumpAndSettle();
    await next(tester);
    await shot(tester, 'return_step_review_phone');
  });

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

    expect(find.textContaining('لا يُردّ نقدًا أكثر من 1,000.00'), findsOneWidget);
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
    await tester.enterText(find.descendant(of: find.byType(ReturnReasonInput), matching: find.byType(TextFormField)), 'عيب');
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

    // The whole return of a sale with a piece asks its label too (the owner,
    // 23 Nov 2026: «لا يوجد حقل لمسح المرتجع» on «عكس الفاتورة كاملة»).
    testWidgets('a piece reversed whole says its label first, and its label missing is printed again', (tester) async {
      final api = FakeSalesApi(invoices: {10: original}, returnLines: {
        10: {
          'invoice_id': 10, 'returned_before': false, 'refundable': 1000.0,
          'lines': [
            {'id': 100, 'name': 'بنجرة', 'karat': 21, 'sold_grams': 2.0, 'remaining_grams': 2.0,
             'sold_pieces': 1, 'remaining_pieces': 1, 'sold_amount': 1000.0, 'remaining_amount': 1000.0,
             'item_id': 43, 'item_code': 'KJ-000007', 'is_piece': true},
          ],
        },
      });
      await open(tester, api: api);
      await reason(tester);
      await pay(tester, 1);
      expect(find.textContaining('امسح بطاقة KJ-000007'), findsWidgets, reason: 'its label unsaid: not ready');
      await tester.tap(find.byKey(const Key('return-tag-100-missing')));
      await tester.pumpAndSettle();
      await tester.tap(reverseButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('عكس وحفظ'));
      await tester.pumpAndSettle();
      expect(api.reversed.single['tags'], {'100': {'missing': true}});
      final (pieceId, body) = api.printsAsked.single;
      expect((pieceId, body['kind'], body['run']), (43, 'reprint', true));
    });

    // The owner's rehearsal, 23 Nov 2026: the focus where the reader types, no tap between pieces.
    testWidgets('the reader reads one piece after another: the focus moves itself', (tester) async {
      final api = FakeSalesApi(invoices: {10: original}, returnLines: {
        10: {
          'invoice_id': 10, 'returned_before': false, 'refundable': 1000.0,
          'lines': [
            for (final (id, code) in [(100, 'KJ-000007'), (101, 'KJ-000008')])
              {'id': id, 'name': 'بنجرة', 'karat': 21, 'sold_grams': 1.0, 'remaining_grams': 1.0,
               'sold_pieces': 1, 'remaining_pieces': 1, 'sold_amount': 500.0, 'remaining_amount': 500.0,
               'item_id': id - 57, 'item_code': code, 'is_piece': true},
          ],
        },
      })
        ..activeTags = {'4B4A00010000000000000007': 'KJ-000007', '4B4A00010000000000000008': 'KJ-000008'};
      await open(tester, api: api);
      bool focused(String key) => tester
          .widget<EditableText>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText)))
          .focusNode
          .hasFocus;
      expect(focused('return-tag-100'), isTrue, reason: 'the first piece, at once');
      await tester.enterText(find.byKey(const Key('return-tag-100')), '4B4A00010000000000000008');
      await tester.pumpAndSettle();
      expect(focused('return-tag-100'), isTrue, reason: 'not its label: read again here');
      await tester.enterText(find.byKey(const Key('return-tag-100')), '4B4A00010000000000000007');
      await tester.pumpAndSettle();
      expect(focused('return-tag-101'), isTrue, reason: 'said: the next piece takes the focus');
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

    // RETURN-OWED-1 (the owner, 8 Oct 2026): what was paid is given back,
    // and the rest of the debt goes with the goods.
    testWidgets('an original paid in part refunds what was paid, and says '
        'what of the debt goes', (tester) async {
      final api = FakeSalesApi(
        invoices: {
          10: {...original, 'amount_paid': 600.0},
        },
      );
      await open(tester, api: api);
      expect(find.textContaining('يُرَدّ ما دُفع: 600.00'), findsOneWidget);
      expect(find.textContaining('يسقط من دين العميل: 400.00'), findsOneWidget);

      await reason(tester);
      await pay(tester, 1);
      expect(find.text('جاهز للحفظ'), findsOneWidget);
      await tester.tap(reverseButton());
      await tester.pumpAndSettle();
      expect(find.textContaining('يسقط من دين العميل: 400.00'), findsWidgets);
      await tester.tap(find.text('عكس وحفظ'));
      await tester.pumpAndSettle();

      expect((api.reversed.single['payments'] as List).single, {
        'payment_method_id': 1,
        'amount': 600.0,
      });
    });

    testWidgets('an original never paid is reversed refunding nothing', (
      tester,
    ) async {
      final api = FakeSalesApi(
        invoices: {
          10: {...original, 'amount_paid': 0.0},
        },
      );
      await open(tester, api: api);
      expect(find.byKey(const Key('quick-pay-1')), findsNothing);
      expect(find.textContaining('لم يُدفع فيها شيء'), findsOneWidget);

      await reason(tester);
      await tester.pumpAndSettle();
      expect(find.text('جاهز للحفظ'), findsOneWidget);
      await tester.tap(reverseButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('عكس وحفظ'));
      await tester.pumpAndSettle();

      expect(api.reversed.single['payments'], isEmpty);
    });

    testWidgets('an original that could not be loaded says why, not «loading»', (
      tester,
    ) async {
      await open(tester, api: FakeSalesApi()); // invoice 10 is not there

      expect(find.textContaining('تعذّر تحميل الفاتورة'), findsWidgets);
      expect(find.textContaining('جارٍ تحميل الفاتورة'), findsNothing);
    });
  });

  // The owner, 11 Nov 2026: «الوزن والمبلغ المرتجع يكتب يدويا فلا يحكم مبلغ
  // السطر الاصلي سعر المرتجع» -- a line comes back for what is typed, within
  // what remains of it; what remains is the server's.
  group('a line comes back for what is typed (the owner, 11 Nov 2026)', () {
    Future<void> toReview(WidgetTester tester, {bool pay = true}) async {
      await next(tester);
      await tester.enterText(
        find.descendant(of: find.byType(ReturnReasonInput), matching: find.byType(TextFormField)),
        'عيب في الصنع',
      );
      await next(tester);
      if (pay) {
        await tester.tap(find.text('وسيلة الدفع').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(find.text('نقداً').last);
        await tester.pumpAndSettle();
      }
      await next(tester);
    }

    Future<Map<String, dynamic>> save(WidgetTester tester, FakeSalesApi api) async {
      await tester.tap(find.text('حفظ').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('اعتماد وحفظ'));
      await tester.pumpAndSettle();
      return api.added.single;
    }

    testWidgets('a line without its amount does not go on, and says so', (tester) async {
      await open(tester);
      await tester.tap(find.text('إرجاع جزء فقط'));
      await tester.pumpAndSettle();
      await next(tester);
      expect(find.text('اكتب المبلغ المرتجع عن «سلسال»'), findsOneWidget);
      expect(find.text('اختر الأصناف المرتجعة'), findsOneWidget, reason: 'still at the lines');
    });

    testWidgets('it is saved for the amount typed, less than the line sold for', (tester) async {
      final api = await open(tester);
      await tester.tap(find.text('إرجاع جزء فقط'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('amount-100-0')), '700');
      await tester.pumpAndSettle();
      await toReview(tester);
      final sent = await save(tester, api);
      expect(sent['total'], 700.0, reason: 'its lines, not the weight\'s share of 1,000');
      expect(((sent['items'] as List).single as Map)['price'], 700.0);
      expect(((sent['items'] as List).single as Map)['weight'], 2.0);
      expect(sent['amount_paid'], 700.0);
    });

    testWidgets('a sale with no branch comes back (289 of 1,987 sales have none)', (tester) async {
      final api = await open(tester, api: FakeSalesApi(invoices: {10: {...original, 'branch_id': null}}));
      await tester.tap(find.text('إرجاع جزء فقط'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('amount-100-0')), '1000');
      await tester.pumpAndSettle();
      await toReview(tester);
      final sent = await save(tester, api);
      expect(sent['branch_id'], isNull, reason: 'its original\'s: none -- the server takes it');
    });

    testWidgets('a sale never paid comes back paying nothing back, no method asked', (tester) async {
      final api = await open(tester, api: FakeSalesApi(invoices: {10: {...original, 'amount_paid': 0.0}}));
      await tester.tap(find.text('إرجاع جزء فقط'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('amount-100-0')), '1000');
      await tester.pumpAndSettle();
      await next(tester);
      await tester.enterText(
        find.descendant(of: find.byType(ReturnReasonInput), matching: find.byType(TextFormField)),
        'عيب في الصنع',
      );
      await next(tester);
      expect(find.byKey(const Key('return-nothing-to-refund')), findsOneWidget);
      await next(tester);
      final sent = await save(tester, api);
      expect(sent['payments'], isEmpty);
      expect(sent['amount_paid'], 0.0);
      expect(sent['total'], 1000.0);
    });

    testWidgets('a sale returned before opens on what remains of it', (tester) async {
      await open(tester, api: FakeSalesApi(invoices: {10: original}, returnLines: {
        10: {
          'invoice_id': 10, 'returned_before': true, 'refundable': 500.0,
          'lines': [
            {'id': 100, 'name': 'سلسال', 'karat': 21, 'sold_grams': 2.0, 'remaining_grams': 1.0,
             'sold_pieces': 1, 'remaining_pieces': 1, 'sold_amount': 1000.0, 'remaining_amount': 500.0},
          ],
        },
      }));
      expect(find.text('عكس الفاتورة #10 كاملة'), findsNothing, reason: 'no whole reversal of what was returned');
      expect(find.text('اختر الأصناف المرتجعة'), findsOneWidget);
      expect(find.textContaining('يبقى منه 1.000 جم'), findsOneWidget);
    });

    // «القطعة ترجع كاملة وأجرتها من بيعها» (the owner, 18 Nov 2026): the line
    // names its piece, which comes back whole -- its weight is not typed.
    testWidgets('a piece comes back whole, named', (tester) async {
      final api = await open(tester, api: FakeSalesApi(invoices: {10: original}, returnLines: {
        10: {
          'invoice_id': 10, 'returned_before': false, 'refundable': 1000.0,
          'lines': [
            {'id': 100, 'name': 'بنجرة', 'karat': 21, 'sold_grams': 13.0, 'remaining_grams': 13.0,
             'sold_pieces': 1, 'remaining_pieces': 1, 'sold_amount': 1000.0, 'remaining_amount': 1000.0,
             'item_id': 43, 'item_code': 'KJ-000007', 'is_piece': true},
          ],
        },
      }));
      await tester.tap(find.text('إرجاع جزء فقط'));
      await tester.pumpAndSettle();
      expect(find.text('القطعة KJ-000007 تُرجَع كاملة'), findsOneWidget);
      final weight = find.descendant(of: find.byKey(const ValueKey('weight-100-0')), matching: find.byType(EditableText));
      expect(tester.widget<EditableText>(weight).readOnly, isTrue);
      await tester.enterText(find.byKey(const ValueKey('amount-100-0')), '1000');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('return-tag-100-missing')));
      await tester.pumpAndSettle();
      await toReview(tester);
      final line = ((await save(tester, api))['items'] as List).single as Map;
      expect((line['item_id'], line['weight']), (43, 13.0));
    });

    // «الزبون قد يتلف البطاقة» (the owner, 23 Nov 2026; ADR-097): the reader
    // decides -- its tag read, its printed number, or a label printed again.
    FakeSalesApi pieceSold() => FakeSalesApi(invoices: {10: original}, returnLines: {
          10: {
            'invoice_id': 10, 'returned_before': false, 'refundable': 1000.0,
            'lines': [
              {'id': 100, 'name': 'بنجرة', 'karat': 21, 'sold_grams': 13.0, 'remaining_grams': 13.0,
               'sold_pieces': 1, 'remaining_pieces': 1, 'sold_amount': 1000.0, 'remaining_amount': 1000.0,
               'item_id': 43, 'item_code': 'KJ-000007', 'is_piece': true},
            ],
          },
        })
          ..activeTags = {'4B4A00010000000000000007': 'KJ-000007', '4B4A00010000000000000008': 'KJ-000008'}
          ..piecesByTyped = {
            'KJ-000007': {'id': 43, 'item_code': 'KJ-000007'},
          };

    Future<void> lineOf(WidgetTester tester) async {
      await tester.tap(find.text('إرجاع جزء فقط'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('amount-100-0')), '1000');
      await tester.pumpAndSettle();
    }

    String said(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('return-tag-100-state'))).data!;

    testWidgets('a piece does not come back with its label unsaid', (tester) async {
      final api = await open(tester, api: pieceSold());
      await lineOf(tester);
      await toReview(tester);
      await tester.tap(find.text('حفظ').hitTestable());
      await tester.pumpAndSettle();
      if (find.text('اعتماد وحفظ').evaluate().isNotEmpty) {
        await tester.tap(find.text('اعتماد وحفظ'));
        await tester.pumpAndSettle();
      }
      expect(api.added, isEmpty);
      expect(find.textContaining('امسح بطاقة KJ-000007'), findsOneWidget);
    });

    testWidgets('its own tag, read by the reader with no Enter: it comes back with its label', (tester) async {
      final api = await open(tester, api: pieceSold());
      await lineOf(tester);
      await tester.enterText(find.byKey(const Key('return-tag-100')), '4B4A00010000000000000008');
      await tester.pumpAndSettle();
      expect(said(tester), contains('KJ-000008'), reason: 'another piece\'s tag is never taken');
      await tester.enterText(find.byKey(const Key('return-tag-100')), '4B4A00010000000000000007');
      await tester.pumpAndSettle();
      expect(said(tester), startsWith('رقاقة القطعة — تعود ببطاقتها'));
      expect(said(tester), allOf(contains('12.40'), contains('بنجرة الشمس')), reason: 'what is in the hand');
      await toReview(tester);
      final line = ((await save(tester, api))['items'] as List).single as Map;
      expect(line['tag'], {'value': '4B4A00010000000000000007'});
      expect(api.printsAsked, isEmpty, reason: 'its label is with it');
    });

    testWidgets('its printed number typed: its tag read by the first count', (tester) async {
      final api = await open(tester, api: pieceSold());
      await lineOf(tester);
      await tester.enterText(find.byKey(const Key('return-tag-100')), 'KJ-000007');
      await tester.pumpAndSettle();
      expect(said(tester), 'الرقم المطبوع للقطعة — تُقرأ رقاقتها في أول جرد بالمسح');
      await toReview(tester);
      final line = ((await save(tester, api))['items'] as List).single as Map;
      expect(line['tag'], {'value': 'KJ-000007'});
    });

    testWidgets('its label missing: printed again after the save, now or waiting', (tester) async {
      final api = await open(tester, api: pieceSold());
      await lineOf(tester);
      await tester.tap(find.byKey(const Key('return-tag-100-missing')));
      await tester.pumpAndSettle();
      expect(said(tester), 'تُطبع للقطعة بطاقة جديدة بعد حفظ المرتجع');
      await tester.tap(find.text('تسجيل فقط'));
      await tester.pumpAndSettle();
      await toReview(tester);
      final line = ((await save(tester, api))['items'] as List).single as Map;
      expect(line['tag'], {'missing': true});
      final (pieceId, body) = api.printsAsked.single;
      expect((pieceId, body['kind'], body['run']), (43, 'reprint', false));
      expect(body['reason'], contains('مرتجع بيع'));
    });
  });
}
