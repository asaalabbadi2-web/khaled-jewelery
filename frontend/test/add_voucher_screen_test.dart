import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_voucher_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voucher_api.dart';

/// VOUCHER-UX-1 (the owner, 9 Oct 2026): a manual voucher -- about two a day
/// on the 6 Oct copy, 443 payments, 40 receipts -- is read as typed, says what
/// stands in the way of saving, and is reviewed before it is saved. 21 manual
/// vouchers (305,210) were cancelled, most within minutes, as «خطأ», «تعديل»,
/// «تصحيح», and four as duplicates.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<FakeVoucherApi> open(
    WidgetTester tester, {
    FakeVoucherApi? api,
  }) async {
    api ??= FakeVoucherApi();
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
            child: AddVoucherScreen(
              voucherType: 'payment',
              initialSupplierId: 5,
              apiService: api,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  Finder cashAmount() =>
      find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first;

  /// The safe the payment is paid from, picked as the employee picks it.
  Future<void> pickSafe(WidgetTester tester) async {
    await tester.tap(find.text('اختر حساب/خزينة').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('الصندوق').last);
    await tester.pumpAndSettle();
  }

  /// Save, as the employee does: the footer's button, then the review's.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text('حفظ السند').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voucher-review-save')));
    await tester.pumpAndSettle();
  }

  double cashSent(FakeVoucherApi api) {
    final lines = (api.created.single['account_lines'] as List)
        .map((l) => Map<String, dynamic>.from(l as Map));
    return lines
        .where((l) => l['account_id'] == 70)
        .fold<double>(0, (s, l) => s + (l['amount'] as num).toDouble());
  }

  group('a number is read as it is typed (stage 1)', () {
    testWidgets('a cash payment is saved with what was typed', (tester) async {
      final api = await open(tester);
      await pickSafe(tester);
      await tester.enterText(cashAmount(), '500');
      await tester.pump();
      await save(tester);

      expect(api.created, hasLength(1));
      expect(cashSent(api), 500.0);
    });

    for (final (typed, meant) in [
      ('1,000', 1000.0),
      ('١،٠٠٠', 1000.0),
      ('١٬٢٥٠٫٥', 1250.5),
    ]) {
      testWidgets('«$typed» is $meant, not nothing', (tester) async {
        final api = await open(tester);
        await pickSafe(tester);
        await tester.enterText(cashAmount(), typed);
        await tester.pump();
        await save(tester);

        expect(api.created, hasLength(1));
        expect(cashSent(api), meant);
      });
    }
  });

  group('ready, said and kept (stage 2)', () {
    Finder footer(String text) => find.textContaining(text);

    testWidgets('it says what stands in the way, then that it is ready', (
      tester,
    ) async {
      await open(tester);
      expect(footer('غير جاهز للحفظ — اختر حساب السطر 1'), findsOneWidget);

      await pickSafe(tester);
      expect(footer('غير جاهز للحفظ — أدخل مبلغ السطر 1'), findsOneWidget);

      await tester.enterText(cashAmount(), '500');
      await tester.pump();
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('it is not saved while not ready, however it is asked', (
      tester,
    ) async {
      final api = await open(tester);
      await tester.enterText(cashAmount(), '500');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(api.created, isEmpty);
    });

    testWidgets('leaving with an amount typed asks first, and can keep it '
        'as a draft', (tester) async {
      await open(tester);
      await tester.enterText(cashAmount(), '500');
      await tester.pump();

      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('سند غير محفوظ'), findsOneWidget);
      expect(find.text('احفظه مسودة واخرج'), findsOneWidget);
    });

    testWidgets('leaving with nothing typed does not ask', (tester) async {
      await open(tester);

      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('سند غير محفوظ'), findsNothing);
    });
  });

  group('reviewed before it is saved (stage 3)', () {
    Future<void> ready(WidgetTester tester) async {
      await pickSafe(tester);
      await tester.enterText(cashAmount(), '500');
      await tester.pump();
    }

    Future<void> askToSave(WidgetTester tester) async {
      await tester.tap(find.text('حفظ السند').last);
      await tester.pumpAndSettle();
    }

    testWidgets('saving shows what is about to be saved, and sends nothing '
        'yet', (tester) async {
      final api = await open(tester);
      await ready(tester);
      await askToSave(tester);

      final review = find.byType(AlertDialog);
      expect(find.text('مراجعة سند صرف'), findsOneWidget);
      expect(
        find.descendant(of: review, matching: find.textContaining('مورد الذهب')),
        findsWidgets,
      );
      expect(
        find.descendant(of: review, matching: find.textContaining('500.00')),
        findsWidgets,
      );
      expect(
        find.descendant(of: review, matching: find.textContaining('الصندوق')),
        findsWidgets,
      );
      expect(api.created, isEmpty);
    });

    testWidgets('back from the review sends nothing and keeps what was typed',
        (tester) async {
      final api = await open(tester);
      await ready(tester);
      await askToSave(tester);

      await tester.tap(find.text('رجوع'));
      await tester.pumpAndSettle();

      expect(api.created, isEmpty);
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('confirmed, it is saved once', (tester) async {
      final api = await open(tester);
      await ready(tester);
      await save(tester);

      expect(api.created, hasLength(1));
    });

    testWidgets('Ctrl+S on a ready voucher opens its review', (tester) async {
      await open(tester);
      await ready(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('مراجعة سند صرف'), findsOneWidget);
    });

    testWidgets('a voucher like one saved is said, and can still be saved', (
      tester,
    ) async {
      final api = FakeVoucherApi(
        similar: const [
          {
            'id': 77,
            'voucher_number': 'PV-2026-00077',
            'date': '2026-10-02T00:00:00',
            'amount_cash': 500.0,
            'amount_gold': 0.0,
            'status': 'approved',
          },
        ],
      );
      await open(tester, api: api);
      await ready(tester);
      await askToSave(tester);

      expect(api.similarAsked.single['supplier_id'], 5);
      expect(find.textContaining('سند مشابه'), findsOneWidget);
      expect(find.textContaining('PV-2026-00077'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voucher-review-save')));
      await tester.pumpAndSettle();
      expect(api.created, hasLength(1));
    });
  });

  group('paid to the invoices chosen, oldest first (VOUCHER-ATTR-1)', () {
    const openCash = [
      {'invoice_id': 12, 'invoice_number': 'PI-0012', 'date': '2026-09-02T00:00:00', 'open_cash': 800.0},
      {'invoice_id': 11, 'invoice_number': 'PI-0011', 'date': '2026-09-01T00:00:00', 'open_cash': 700.0},
    ];
    const plan = {
      'cash': [
        {'invoice_id': 11, 'amount': 700.0},
        {'invoice_id': 12, 'amount': 300.0},
      ],
      'gold': [],
      'cash_on_account': 0.0,
      'gold_on_account_main_karat': 0.0,
      'invoices': [
        {'invoice_id': 11, 'invoice_number': 'PI-0011', 'date': '2026-09-01T00:00:00'},
        {'invoice_id': 12, 'invoice_number': 'PI-0012', 'date': '2026-09-02T00:00:00'},
      ],
    };

    Future<void> choose(WidgetTester tester, int id) async {
      await tester.tap(find.byKey(Key('invoice-pick-$id')));
      await tester.pumpAndSettle();
    }

    Future<void> ready(WidgetTester tester, [String amount = '1000']) async {
      await pickSafe(tester);
      await tester.enterText(cashAmount(), amount);
      await tester.pumpAndSettle();
    }

    String description(WidgetTester tester) => tester
        .widget<TextField>(
          find.descendant(
            of: find.byKey(const Key('voucher-description')),
            matching: find.byType(TextField),
          ),
        )
        .controller!
        .text;

    testWidgets('the supplier\'s open invoices are listed oldest first, by '
        'number, with what each owes', (tester) async {
      await open(tester, api: FakeVoucherApi(openCash: openCash));

      final first = tester.getTopLeft(find.byKey(const Key('invoice-pick-11')));
      final second = tester.getTopLeft(find.byKey(const Key('invoice-pick-12')));
      expect(first.dy, lessThan(second.dy));
      expect(find.textContaining('PI-0011'), findsWidgets);
      expect(find.textContaining('700.00'), findsWidgets);
    });

    testWidgets('choosing invoices asks the server how the payment spreads, '
        'and shows each its share', (tester) async {
      final api = FakeVoucherApi(openCash: openCash, plan: plan);
      await open(tester, api: api);
      await ready(tester);

      await choose(tester, 12);
      await choose(tester, 11);

      final asked = api.planAsked.last;
      expect(asked['supplier_id'], 5);
      expect((asked['invoice_ids'] as List).toSet(), {11, 12});
      expect(asked['cash'], 1000.0);
      expect(
        find.descendant(
          of: find.byKey(const Key('invoice-share-11')),
          matching: find.textContaining('700.00'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('invoice-share-12')),
          matching: find.textContaining('300.00'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('what the chosen invoices do not owe is said to stay on '
        'account', (tester) async {
      final api = FakeVoucherApi(
        openCash: openCash,
        plan: {
          ...plan,
          'cash': [
            {'invoice_id': 11, 'amount': 700.0},
          ],
          'cash_on_account': 300.0,
        },
      );
      await open(tester, api: api);
      await ready(tester);
      await choose(tester, 11);

      expect(
        find.descendant(
          of: find.byKey(const Key('invoice-on-account')),
          matching: find.textContaining('300.00'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the description names the invoices, and a hand-written one '
        'is kept', (tester) async {
      final api = FakeVoucherApi(openCash: openCash, plan: plan);
      await open(tester, api: api);
      await ready(tester);

      await choose(tester, 11);
      expect(description(tester), 'سداد دفعة لفاتورة رقم PI-0011');

      await choose(tester, 12);
      expect(description(tester), 'سداد دفعة لفواتير رقم PI-0011، PI-0012');

      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('voucher-description')),
          matching: find.byType(TextField),
        ),
        'دفعة متفق عليها',
      );
      await choose(tester, 12);
      expect(description(tester), 'دفعة متفق عليها');
    });

    testWidgets('it is saved with the chosen invoices, the server spreading it',
        (tester) async {
      final api = FakeVoucherApi(openCash: openCash, plan: plan);
      await open(tester, api: api);
      await ready(tester);
      await choose(tester, 12);
      await choose(tester, 11);
      await save(tester);

      final sent = api.created.single;
      expect((sent['invoice_ids'] as List).toSet(), {11, 12});
      expect(sent.containsKey('reference_id'), isFalse);
    });

    testWidgets('the review shows each invoice\'s share and what stays on '
        'account', (tester) async {
      final api = FakeVoucherApi(
        openCash: openCash,
        plan: {
          ...plan,
          'cash': [
            {'invoice_id': 11, 'amount': 700.0},
          ],
          'cash_on_account': 300.0,
        },
      );
      await open(tester, api: api);
      await ready(tester);
      await choose(tester, 11);
      await tester.tap(find.text('حفظ السند').last);
      await tester.pumpAndSettle();

      final review = find.byType(AlertDialog);
      expect(
        find.descendant(of: review, matching: find.textContaining('PI-0011')),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: review,
          matching: find.textContaining('يبقى على حساب المورد'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('with no invoice chosen it is saved on the supplier\'s '
        'account', (tester) async {
      final api = FakeVoucherApi(openCash: openCash, plan: plan);
      await open(tester, api: api);
      await ready(tester);
      await save(tester);

      expect(api.created.single.containsKey('invoice_ids'), isFalse);
    });

    testWidgets('the amount can be filled with what the chosen invoices owe',
        (tester) async {
      final api = FakeVoucherApi(openCash: openCash, plan: plan);
      await open(tester, api: api);
      await pickSafe(tester);
      await choose(tester, 11);
      await choose(tester, 12);

      await tester.tap(find.byKey(const Key('fill-from-invoices')));
      await tester.pumpAndSettle();
      await save(tester);

      expect(cashSent(api), 1500.0);
    });
  });
}
